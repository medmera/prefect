#!/bin/bash
# Shared helpers for preparing release-prep/<tag> branches.
# Sourced by prepare-release-branch.sh and mmb-prepare-release.sh — do not execute directly.

: "${UPSTREAM_REMOTE:=upstream}"
: "${ORIGIN_REMOTE:=origin}"
: "${RELEASE_BRANCH:=release}"
: "${UPSTREAM_URL:=https://github.com/PrefectHQ/prefect.git}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_step()    { echo -e "${BLUE}[STEP]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }

prep_branch_for_tag() {
    echo "release-prep/${1}"
}

ensure_upstream_remote() {
    if git remote | grep -q "^${UPSTREAM_REMOTE}$"; then
        return 0
    fi
    print_step "Adding '${UPSTREAM_REMOTE}' remote (${UPSTREAM_URL})..."
    git remote add "${UPSTREAM_REMOTE}" "${UPSTREAM_URL}"
    print_success "Remote '${UPSTREAM_REMOTE}' added"
}

require_git_repo() {
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        print_error "Not in a git repository"
        return 1
    fi
}

require_clean_working_tree() {
    if ! git diff-index --quiet HEAD --; then
        print_error "Working tree has uncommitted changes. Please commit or stash first."
        git status --porcelain >&2
        return 1
    fi
}

fetch_remotes() {
    print_step "Fetching all remotes and tags..."

    if git remote | grep -q "^${UPSTREAM_REMOTE}$"; then
        git fetch "${UPSTREAM_REMOTE}" --tags --quiet
    else
        print_warning "No '${UPSTREAM_REMOTE}' remote found — relying on tags already present"
    fi
    git fetch "${ORIGIN_REMOTE}" --tags --quiet
    print_success "Fetch complete"
}

validate_tag() {
    local base_tag="$1"

    if ! git rev-parse "${base_tag}" >/dev/null 2>&1; then
        print_error "Tag '${base_tag}' not found after fetch."
        echo ""
        echo "Tags matching pattern:"
        git tag -l "${base_tag}*" | head -10
        return 1
    fi

    TAG_COMMIT=$(git rev-parse "${base_tag}")
    RELEASE_COMMIT=$(git rev-parse "${ORIGIN_REMOTE}/${RELEASE_BRANCH}")

    print_step "Tag '${base_tag}' → ${TAG_COMMIT:0:10}"
    print_step "release HEAD   → ${RELEASE_COMMIT:0:10}"
    echo ""

    if git merge-base --is-ancestor "${base_tag}" "${RELEASE_COMMIT}"; then
        print_warning "Tag '${base_tag}' is already an ancestor of ${RELEASE_BRANCH}."
        print_warning "Nothing to do — release is already up to date with this tag."
        return 2
    fi

    return 0
}

show_dry_run_preview() {
    local base_tag="$1"
    local prep_branch
    prep_branch="$(prep_branch_for_tag "${base_tag}")"

    echo ""
    print_step "DRY RUN — no changes will be made"
    echo ""
    if git ls-remote --exit-code "${ORIGIN_REMOTE}" "refs/heads/${prep_branch}" >/dev/null 2>&1; then
        echo "Would reset existing branch: ${prep_branch}"
    else
        echo "Would create branch: ${prep_branch}"
    fi
    echo "  from: ${ORIGIN_REMOTE}/${RELEASE_BRANCH} (${RELEASE_COMMIT:0:10})"
    echo "  merge: ${base_tag} (${TAG_COMMIT:0:10})"
    echo ""
    echo "Commits in ${base_tag} not yet in ${RELEASE_BRANCH}:"
    git log --oneline "${RELEASE_COMMIT}..${base_tag}" | head -20
}

prep_branch_exists_on_origin() {
    local prep_branch="$1"
    git ls-remote --exit-code "${ORIGIN_REMOTE}" "refs/heads/${prep_branch}" >/dev/null 2>&1
}

create_prep_branch() {
    local prep_branch="$1"

    PREP_BRANCH_EXISTS_ON_ORIGIN=false
    if prep_branch_exists_on_origin "${prep_branch}"; then
        PREP_BRANCH_EXISTS_ON_ORIGIN=true
        print_step "Branch '${prep_branch}' already exists on ${ORIGIN_REMOTE}; resetting from ${ORIGIN_REMOTE}/${RELEASE_BRANCH} and re-merging (retry / idempotent run)."
    else
        print_step "Creating ${prep_branch} from ${ORIGIN_REMOTE}/${RELEASE_BRANCH}..."
    fi

    git checkout -B "${prep_branch}" "${ORIGIN_REMOTE}/${RELEASE_BRANCH}"
    if [[ "${PREP_BRANCH_EXISTS_ON_ORIGIN}" == "true" ]]; then
        print_success "Branch reset to match ${ORIGIN_REMOTE}/${RELEASE_BRANCH}"
    else
        print_success "Branch created"
    fi
}

merge_upstream_tag() {
    local base_tag="$1"

    echo ""
    print_step "Merging ${base_tag} into current branch..."

    if git merge "${base_tag}" --no-edit -m "Merge upstream ${base_tag} into release"; then
        print_success "Clean merge — no conflicts"
        return 0
    fi

    print_warning "Merge had conflicts."
    list_conflicted_files
    return 1
}

list_conflicted_files() {
    echo ""
    echo "Conflicted files:"
    git diff --name-only --diff-filter=U | sed 's/^/  /'
    echo ""
}

has_unmerged_paths() {
    [[ -n "$(git diff --name-only --diff-filter=U)" ]]
}

has_conflict_markers() {
    local markers
    markers="$(git grep -l '^<<<<<<< ' -- . 2>/dev/null || true)"
    if [[ -n "${markers}" ]]; then
        echo "${markers}"
        return 0
    fi
    return 1
}

commit_resolved_merge() {
    local base_tag="$1"

    if has_unmerged_paths; then
        print_error "Merge still has unmerged paths. Resolve all conflicts before committing."
        list_conflicted_files
        return 1
    fi

    local marker_files
    if marker_files="$(has_conflict_markers)"; then
        print_error "Conflict markers remain in these files:"
        echo "${marker_files}" | sed 's/^/  /'
        return 1
    fi

    if git diff --check --quiet; then
        :
    else
        print_error "Whitespace or conflict issues detected (git diff --check failed)."
        return 1
    fi

    git add --all
    git commit \
        -m "Merge upstream ${base_tag} into release" \
        --no-verify
    print_success "Resolved merge committed"
}

commit_conflict_markers() {
    local base_tag="$1"

    print_warning "Committing conflict markers for PR review (headless mode)."
    git add --all
    git commit \
        -m "Merge upstream ${base_tag} into release [CONFLICTS NEED RESOLUTION]" \
        -m "The following files have merge conflicts that must be resolved before" \
        -m "merging this PR into release:" \
        -m "$(git diff --cached --name-only --diff-filter=U 2>/dev/null || git show --stat HEAD | tail -n +2)" \
        --no-verify
    print_warning "Conflict markers committed. Resolve them before merging the PR."
}

push_prep_branch() {
    local prep_branch="$1"

    echo ""
    print_step "Pushing ${prep_branch} to ${ORIGIN_REMOTE}..."
    if [[ "${PREP_BRANCH_EXISTS_ON_ORIGIN:-false}" == "true" ]]; then
        git push --force-with-lease "${ORIGIN_REMOTE}" "${prep_branch}"
    else
        git push "${ORIGIN_REMOTE}" "${prep_branch}"
    fi
    print_success "Branch pushed: ${ORIGIN_REMOTE}/${prep_branch}"
}

abort_merge_and_restore() {
    local original_branch="$1"

    if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
        git merge --abort
    fi
    if [[ -n "${original_branch}" ]] && git show-ref --verify --quiet "refs/heads/${original_branch}"; then
        git checkout "${original_branch}" >/dev/null 2>&1 || true
    fi
}
