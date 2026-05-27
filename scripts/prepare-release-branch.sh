#!/bin/bash

# Headless script to prepare a release-prep branch by merging an upstream tag into
# the current release branch and pushing it for PR review.
#
# For interactive conflict resolution and automatic PR creation, use:
#   ./scripts/mmb-prepare-release.sh <tag>
#
# Usage:
#   prepare-release-branch.sh [--dry-run] [--commit-conflicts] <tag>
#
# Examples:
#   prepare-release-branch.sh 3.4.25
#   prepare-release-branch.sh --dry-run 3.4.25
#   prepare-release-branch.sh --commit-conflicts 3.4.25

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=prepare-release-branch-lib.sh
source "${SCRIPT_DIR}/prepare-release-branch-lib.sh"

DRY_RUN=false
COMMIT_CONFLICTS=false
BASE_TAG=""

show_help() {
    cat <<EOF
Usage: $0 [--dry-run] [--commit-conflicts] <tag>

Prepare a release-prep/<tag> branch by merging <tag> into the current
release branch, then push it for PR review.

Arguments:
  <tag>        Upstream tag to merge (e.g. 3.4.25)

Options:
  --dry-run           Show what would be done without making changes
  --commit-conflicts  Commit conflict markers and push (headless emergency use)
  -h, --help          Show this help

The script:
  1. Fetches all remotes and tags
  2. Creates release-prep/<tag> from origin/release, or resets an existing
     remote prep branch to match release (safe to rerun)
  3. Merges <tag> into that branch
  4. On conflicts: exits with code 2 unless --commit-conflicts is set
  5. Pushes the branch (unless --dry-run)

Prefer ./scripts/mmb-prepare-release.sh for the normal local release workflow.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)            show_help; exit 0 ;;
        --dry-run)            DRY_RUN=true; shift ;;
        --commit-conflicts)   COMMIT_CONFLICTS=true; shift ;;
        -*)                   print_error "Unknown option: $1"; show_help; exit 1 ;;
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
    echo "  ./scripts/mmb-prepare-release.sh ${BASE_TAG}"
    exit 0
fi

create_prep_branch "${PREP_BRANCH}"

CONFLICTS=false
if merge_upstream_tag "${BASE_TAG}"; then
    :
else
    CONFLICTS=true
    if [[ "${COMMIT_CONFLICTS}" == "true" ]]; then
        commit_conflict_markers "${BASE_TAG}"
    else
        print_error "Merge has conflicts. Resolve them locally with:"
        echo "  ./scripts/mmb-prepare-release.sh ${BASE_TAG}"
        exit 2
    fi
fi

push_prep_branch "${PREP_BRANCH}"

if [[ "${CONFLICTS}" == "true" ]]; then
    echo ""
    print_warning "RESULT: conflicts were committed. PR needs manual resolution."
else
    print_success "RESULT: clean merge. Branch is ready for PR review."
fi
