#!/bin/bash
#
# create-mmb-release-tags.sh
#
# Creates and pushes annotated MMB release tags for each package that was
# successfully uploaded during a release run.
#
# Expected environment variables:
#   RELEASE_TAGS  Comma-separated list of tag names, e.g.:
#                 "3.4.25-mmb,prefect-gcp-0.6.17-mmb,prefect-aws-0.5.13-mmb"
#                 "3.7.2.post1-mmb" (post-release patch)
#
# The script is idempotent:
#   - If a tag already points at the current HEAD it is skipped (safe to re-run).
#   - If a tag already points at a *different* commit it is treated as an error
#     (refuse to silently move tags).
#
# Usage (called by the GitHub Actions workflow):
#   RELEASE_TAGS="3.4.25-mmb,prefect-gcp-0.6.17-mmb" ./scripts/create-mmb-release-tags.sh
#   RELEASE_TAGS="3.7.2.post1-mmb" ./scripts/create-mmb-release-tags.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
warn()    { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" >&2; }
success() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] SUCCESS:${NC} $1"; }
error()   { echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2; exit 1; }

# ---- Validate inputs --------------------------------------------------------

if [[ -z "${RELEASE_TAGS:-}" ]]; then
    error "RELEASE_TAGS is not set or empty. Nothing to tag."
fi

# ---- Git configuration (matches other MMB workflows) ------------------------

git config --global user.name "github-actions[bot]"
git config --global user.email "github-actions[bot]@users.noreply.github.com"

# ---- Determine current HEAD -------------------------------------------------

CURRENT_SHA=$(git rev-parse HEAD)
log "Current HEAD: ${CURRENT_SHA}"

# ---- Process each tag -------------------------------------------------------

IFS=',' read -ra TAGS <<< "$RELEASE_TAGS"

tags_to_push=()

for tag in "${TAGS[@]}"; do
    tag="$(echo "$tag" | tr -d '[:space:]')"  # strip any stray whitespace
    [[ -z "$tag" ]] && continue

    # Check whether this tag already exists locally or on the remote
    existing_sha=""
    if git rev-parse --verify "refs/tags/${tag}" &>/dev/null 2>&1; then
        existing_sha=$(git rev-parse "refs/tags/${tag}")
    fi

    if [[ -n "$existing_sha" ]]; then
        if [[ "$existing_sha" == "$CURRENT_SHA" ]]; then
            log "Tag ${tag} already exists at this commit — skipping (idempotent re-run)"
            continue
        else
            error "Tag ${tag} already exists at a DIFFERENT commit (${existing_sha}). Refusing to move it. Delete the tag manually if you intended to re-tag a different commit."
        fi
    fi

    log "Creating annotated tag: ${tag}"
    git tag -a "$tag" -m "MMB release ${tag}"
    tags_to_push+=("$tag")
done

# ---- Push new tags ----------------------------------------------------------

if [[ ${#tags_to_push[@]} -eq 0 ]]; then
    log "No new tags to push."
    exit 0
fi

log "Pushing ${#tags_to_push[@]} new tag(s) to origin..."
git push origin "${tags_to_push[@]}"

for tag in "${tags_to_push[@]}"; do
    success "Pushed tag: ${tag}"
done

echo ""
success "All MMB release tags created and pushed successfully."
