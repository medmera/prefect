#!/bin/bash

# Script to prepare a release-prep branch by merging an upstream tag into
# the current release branch.
#
# This replaces the old reconstruct-release-branch.sh cherry-pick approach.
# Instead of resetting the release branch and replaying MMB commits, we keep
# the release branch alive and merge the new upstream tag into a temporary
# release-prep/<tag> branch. A PR is then opened to merge that into release.
#
# Usage:
#   prepare-release-branch.sh [--dry-run] <tag>
#
# Examples:
#   prepare-release-branch.sh 3.4.25
#   prepare-release-branch.sh --dry-run 3.4.25

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

UPSTREAM_REMOTE="upstream"
ORIGIN_REMOTE="origin"
RELEASE_BRANCH="release"
DRY_RUN=false
BASE_TAG=""

print_step()    { echo -e "${BLUE}[STEP]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }

show_help() {
    cat <<EOF
Usage: $0 [--dry-run] <tag>

Prepare a release-prep/<tag> branch by merging <tag> into the current
release branch, then push it for PR review.

Arguments:
  <tag>        Upstream tag to merge (e.g. 3.4.25)

Options:
  --dry-run    Show what would be done without making changes
  -h, --help   Show this help

The script:
  1. Fetches all remotes and tags
  2. Creates release-prep/<tag> from origin/release
  3. Merges <tag> into that branch
  4. If conflicts: commits conflict markers and sets CONFLICTS output
  5. Pushes the branch (unless --dry-run)

After this script completes, the caller (workflow or human) opens a PR
release-prep/<tag> → release and resolves any conflicts there.
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)   show_help; exit 0 ;;
        --dry-run)   DRY_RUN=true; shift ;;
        -*)          print_error "Unknown option: $1"; show_help; exit 1 ;;
        *)
            if [[ -z "$BASE_TAG" ]]; then
                BASE_TAG="$1"
            else
                print_error "Too many arguments"; show_help; exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$BASE_TAG" ]]; then
    print_error "Missing required argument: <tag>"
    echo ""
    show_help
    exit 1
fi

PREP_BRANCH="release-prep/${BASE_TAG}"

# ── Pre-flight checks ──────────────────────────────────────────────────────────

if ! git rev-parse --git-dir > /dev/null 2>&1; then
    print_error "Not in a git repository"
    exit 1
fi

if ! git diff-index --quiet HEAD --; then
    print_error "Working tree has uncommitted changes. Please commit or stash first."
    git status --porcelain >&2
    exit 1
fi

# ── Fetch ──────────────────────────────────────────────────────────────────────

print_step "Fetching all remotes and tags..."

if git remote | grep -q "^${UPSTREAM_REMOTE}$"; then
    git fetch "$UPSTREAM_REMOTE" --tags --quiet
else
    print_warning "No '${UPSTREAM_REMOTE}' remote found — relying on tags already present"
fi
git fetch "$ORIGIN_REMOTE" --tags --quiet
print_success "Fetch complete"

# ── Validate tag ───────────────────────────────────────────────────────────────

if ! git rev-parse "${BASE_TAG}" >/dev/null 2>&1; then
    print_error "Tag '${BASE_TAG}' not found after fetch."
    echo ""
    echo "Tags matching pattern:"
    git tag -l "${BASE_TAG}*" | head -10
    exit 1
fi

TAG_COMMIT=$(git rev-parse "${BASE_TAG}")
RELEASE_COMMIT=$(git rev-parse "${ORIGIN_REMOTE}/${RELEASE_BRANCH}")

print_step "Tag '${BASE_TAG}' → ${TAG_COMMIT:0:10}"
print_step "release HEAD   → ${RELEASE_COMMIT:0:10}"
echo ""

# Check that this tag isn't already an ancestor of release (i.e. already merged)
if git merge-base --is-ancestor "${BASE_TAG}" "${RELEASE_COMMIT}"; then
    print_warning "Tag '${BASE_TAG}' is already an ancestor of ${RELEASE_BRANCH}."
    print_warning "Nothing to do — release is already up to date with this tag."
    exit 0
fi

# ── Dry run ────────────────────────────────────────────────────────────────────

if [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    print_step "DRY RUN — no changes will be made"
    echo ""
    echo "Would create branch: ${PREP_BRANCH}"
    echo "  from: ${ORIGIN_REMOTE}/${RELEASE_BRANCH} (${RELEASE_COMMIT:0:10})"
    echo "  merge: ${BASE_TAG} (${TAG_COMMIT:0:10})"
    echo ""
    echo "Commits in ${BASE_TAG} not yet in ${RELEASE_BRANCH}:"
    git log --oneline "${RELEASE_COMMIT}..${BASE_TAG}" | head -20
    echo ""
    echo "To run for real:"
    echo "  $0 ${BASE_TAG}"
    exit 0
fi

# ── Check prep branch doesn't already exist ────────────────────────────────────

if git ls-remote --exit-code "$ORIGIN_REMOTE" "refs/heads/${PREP_BRANCH}" >/dev/null 2>&1; then
    print_error "Branch '${PREP_BRANCH}' already exists on origin."
    print_error "Delete it first with: git push origin --delete ${PREP_BRANCH}"
    exit 1
fi

# ── Create prep branch and merge ──────────────────────────────────────────────

print_step "Creating ${PREP_BRANCH} from ${ORIGIN_REMOTE}/${RELEASE_BRANCH}..."
git checkout -b "${PREP_BRANCH}" "${ORIGIN_REMOTE}/${RELEASE_BRANCH}"
print_success "Branch created"

echo ""
print_step "Merging ${BASE_TAG} into ${PREP_BRANCH}..."

CONFLICTS=false

if git merge "${BASE_TAG}" --no-edit -m "Merge upstream ${BASE_TAG} into release"; then
    print_success "Clean merge — no conflicts"
else
    CONFLICTS=true
    print_warning "Merge had conflicts. Committing conflict markers for PR review."
    echo ""
    echo "Conflicted files:"
    git diff --name-only --diff-filter=U | sed 's/^/  /'
    echo ""

    # Stage everything (including conflict markers) and create a commit so the
    # branch is pushable. The PR description will flag these for resolution.
    git add --all
    git commit \
        -m "Merge upstream ${BASE_TAG} into release [CONFLICTS NEED RESOLUTION]" \
        -m "The following files have merge conflicts that must be resolved before" \
        -m "merging this PR into release:" \
        -m "$(git diff --cached --name-only --diff-filter=U 2>/dev/null || git show --stat HEAD | tail -n +2)" \
        --no-verify
    print_warning "Conflict markers committed. Resolve them in the PR branch before merging."
fi

# ── Push ───────────────────────────────────────────────────────────────────────

echo ""
print_step "Pushing ${PREP_BRANCH} to ${ORIGIN_REMOTE}..."
git push "${ORIGIN_REMOTE}" "${PREP_BRANCH}"
print_success "Branch pushed: ${ORIGIN_REMOTE}/${PREP_BRANCH}"

# ── Output for workflow consumption ───────────────────────────────────────────

if [[ "${CONFLICTS}" == "true" ]]; then
    echo ""
    print_warning "RESULT: conflicts were found. PR needs manual resolution."
    # Write to GITHUB_OUTPUT if running inside Actions
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "conflicts=true" >> "$GITHUB_OUTPUT"
        echo "prep_branch=${PREP_BRANCH}" >> "$GITHUB_OUTPUT"
    fi
else
    print_success "RESULT: clean merge. PR is ready to review and merge."
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "conflicts=false" >> "$GITHUB_OUTPUT"
        echo "prep_branch=${PREP_BRANCH}" >> "$GITHUB_OUTPUT"
    fi
fi
