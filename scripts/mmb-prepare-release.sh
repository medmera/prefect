#!/bin/bash

# Prepare an MMB release by merging an upstream Prefect tag into release-prep/<tag>,
# resolving conflicts interactively, pushing the branch, and opening a PR.
#
# Usage:
#   mmb-prepare-release.sh [--dry-run] [--no-pr] [--no-open] <tag>
#
# Examples:
#   mmb-prepare-release.sh --dry-run 3.4.25
#   mmb-prepare-release.sh 3.4.25
#   just mmb-prepare-release 3.4.25

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=prepare-release-branch-lib.sh
source "${SCRIPT_DIR}/prepare-release-branch-lib.sh"

DRY_RUN=false
NO_PR=false
NO_OPEN=false
BASE_TAG=""
ORIGINAL_BRANCH=""
HAD_CONFLICTS=false
PR_URL=""

cleanup() {
    local exit_code=$?

    if [[ "${exit_code}" -ne 0 ]] && git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
        print_warning "Leaving merge in progress on $(git branch --show-current). Run 'git merge --abort' to cancel."
    elif [[ -n "${ORIGINAL_BRANCH}" ]] && [[ "$(git branch --show-current 2>/dev/null || true)" != "${ORIGINAL_BRANCH}" ]]; then
        if git show-ref --verify --quiet "refs/heads/${ORIGINAL_BRANCH}"; then
            git checkout "${ORIGINAL_BRANCH}" >/dev/null 2>&1 || true
        fi
    fi

    return "${exit_code}"
}
trap cleanup EXIT

show_help() {
    cat <<EOF
Usage: $0 [--dry-run] [--no-pr] [--no-open] <tag>

Prepare an MMB upstream merge release locally:
  1. Fetch remotes and validate the upstream tag
  2. Create release-prep/<tag> from origin/release and merge the tag
  3. Resolve conflicts interactively (if any) before pushing
  4. Push the branch and open a PR to release (via gh)

Arguments:
  <tag>        Upstream tag to merge (e.g. 3.4.25)

Options:
  --dry-run    Preview what would happen without making changes
  --no-pr      Push the branch but skip gh pr create
  --no-open    Create the PR but do not open it in a browser
  -h, --help   Show this help

Prerequisites:
  - Clean working tree (commit or stash first)
  - gh CLI authenticated: gh auth login
  - Run mmb-sync-main first so the tag exists on origin

Examples:
  $0 --dry-run 3.4.25
  $0 3.4.25
EOF
}

require_gh() {
    if ! command -v gh >/dev/null 2>&1; then
        print_error "gh CLI is not installed. Install it from https://cli.github.com/"
        exit 1
    fi
    if ! gh auth status >/dev/null 2>&1; then
        print_error "gh is not authenticated. Run: gh auth login"
        exit 1
    fi
}

resolve_conflicts_interactively() {
    local base_tag="$1"

    echo ""
    print_warning "Merge conflicts detected. Resolve them locally before pushing."
    list_conflicted_files

    while true; do
        echo "Options:"
        echo "  [Enter]  Continue after resolving conflicts in your editor"
        echo "  m        Run git mergetool"
        echo "  s        Show git status"
        echo "  d FILE   Show diff for a conflicted file"
        echo "  l        List conflicted files again"
        echo "  a        Abort merge and exit"
        echo ""
        read -r -p "Choice: " choice

        case "${choice}" in
            "")
                if has_unmerged_paths; then
                    print_error "Unmerged paths remain. Resolve all conflicts first."
                    list_conflicted_files
                    continue
                fi
                if marker_files="$(has_conflict_markers)"; then
                    print_error "Conflict markers remain in:"
                    echo "${marker_files}" | sed 's/^/  /'
                    continue
                fi
                if ! git diff --check --quiet 2>/dev/null; then
                    print_error "git diff --check failed. Fix remaining issues before continuing."
                    continue
                fi
                commit_resolved_merge "${base_tag}"
                return 0
                ;;
            m|M)
                git mergetool || true
                ;;
            s|S)
                git status --short
                echo ""
                ;;
            d\ *)
                local file="${choice#d }"
                if [[ -z "${file}" ]]; then
                    read -r -p "File path: " file
                fi
                git diff -- "${file}" || true
                ;;
            l|L)
                list_conflicted_files
                ;;
            a|A)
                print_warning "Aborting merge."
                git merge --abort
                exit 1
                ;;
            *)
                print_warning "Unknown choice: ${choice}"
                ;;
        esac
    done
}

build_pr_body() {
    local base_tag="$1"
    local had_conflicts="$2"

    if [[ "${had_conflicts}" == "true" ]]; then
        cat <<EOF
## Merge upstream ${base_tag} into release

This PR was created by **mmb-prepare-release.sh** (local release prep).

**Base tag:** \`${base_tag}\`
**Merge result:** Conflicts were resolved locally before push

### What this does
Merges the upstream Prefect \`${base_tag}\` tag into the \`release\`
branch, bringing in all upstream changes while preserving MMB customisations.

### Review checklist
- [ ] Confirm the diff looks correct (upstream changes + no unintended modifications)
- [ ] Verify integration package code is at the expected version
- [ ] Merge with a **merge commit** (\`gh pr merge --merge\`) — do NOT squash or rebase
- [ ] Then run **MMB - Release Packages** to publish
EOF
    else
        cat <<EOF
## Merge upstream ${base_tag} into release

This PR was created by **mmb-prepare-release.sh** (local release prep).

**Base tag:** \`${base_tag}\`
**Merge result:** Clean — no conflicts

### What this does
Merges the upstream Prefect \`${base_tag}\` tag into the \`release\`
branch, bringing in all upstream changes while preserving MMB customisations.

### Review checklist
- [ ] Confirm the diff looks correct (upstream changes + no unintended modifications)
- [ ] Verify integration package code is at the expected version
- [ ] Merge with a **merge commit** (\`gh pr merge --merge\`) — do NOT squash or rebase
- [ ] Then run **MMB - Release Packages** to publish
EOF
    fi
}

create_or_find_pr() {
    local base_tag="$1"
    local prep_branch="$2"
    local had_conflicts="$3"

    local existing_pr
    existing_pr="$(gh pr list --head "${prep_branch}" --base "${RELEASE_BRANCH}" --json url --jq '.[0].url // empty' 2>/dev/null || true)"

    if [[ -n "${existing_pr}" ]]; then
        PR_URL="${existing_pr}"
        print_success "Existing PR found: ${PR_URL}"
        return 0
    fi

    local title
    if [[ "${had_conflicts}" == "true" ]]; then
        title="chore: merge upstream ${base_tag} into release [conflicts resolved locally]"
    else
        title="chore: merge upstream ${base_tag} into release"
    fi

    local body_file
    body_file="$(mktemp)"
    build_pr_body "${base_tag}" "${had_conflicts}" > "${body_file}"

    print_step "Creating pull request..."
    PR_URL="$(gh pr create \
        --base "${RELEASE_BRANCH}" \
        --head "${prep_branch}" \
        --title "${title}" \
        --body-file "${body_file}")"
    rm -f "${body_file}"

    print_success "Pull request created: ${PR_URL}"
}

print_summary() {
    local base_tag="$1"
    local prep_branch="$2"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_success "MMB prepare release complete"
    echo ""
    echo "  Tag:          ${base_tag}"
    echo "  Branch:       ${prep_branch}"
    if [[ "${HAD_CONFLICTS}" == "true" ]]; then
        echo "  Merge:        Conflicts resolved locally"
    else
        echo "  Merge:        Clean"
    fi
    if [[ -n "${PR_URL}" ]]; then
        echo "  Pull request: ${PR_URL}"
    elif [[ "${NO_PR}" == "true" ]]; then
        echo "  Pull request: (skipped — use gh pr create manually)"
    fi
    echo ""
    echo "Next steps:"
    echo "  1. Review the PR diff"
    echo "  2. Wait for mmb-python-tests CI to pass"
    echo "  3. Merge the PR with a MERGE COMMIT (gh pr merge --merge). Do NOT squash."
    echo "  4. Dispatch MMB - Release Packages from GitHub Actions"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)   show_help; exit 0 ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --no-pr)     NO_PR=true; shift ;;
        --no-open)   NO_OPEN=true; shift ;;
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

PREP_BRANCH="$(prep_branch_for_tag "${BASE_TAG}")"

require_git_repo
require_clean_working_tree

ORIGINAL_BRANCH="$(git branch --show-current 2>/dev/null || true)"

ensure_upstream_remote
fetch_remotes

if ! validate_tag "${BASE_TAG}"; then
    status=$?
    if [[ "${status}" -eq 2 ]]; then
        exit 0
    fi
    exit "${status}"
fi

if [[ "$DRY_RUN" == "true" ]]; then
    show_dry_run_preview "${BASE_TAG}"
    echo ""
    echo "To run for real:"
    echo "  $0 ${BASE_TAG}"
    exit 0
fi

require_gh

create_prep_branch "${PREP_BRANCH}"

if merge_upstream_tag "${BASE_TAG}"; then
    HAD_CONFLICTS=false
else
    HAD_CONFLICTS=true
    resolve_conflicts_interactively "${BASE_TAG}"
fi

push_prep_branch "${PREP_BRANCH}"

if [[ "${NO_PR}" != "true" ]]; then
    create_or_find_pr "${BASE_TAG}" "${PREP_BRANCH}" "${HAD_CONFLICTS}"
    if [[ "${NO_OPEN}" != "true" && -n "${PR_URL}" ]]; then
        gh pr view "${PR_URL}" --web >/dev/null 2>&1 || true
    fi
fi

print_summary "${BASE_TAG}" "${PREP_BRANCH}"

# Stay on prep branch so the user can inspect; disable restore on success
ORIGINAL_BRANCH=""
