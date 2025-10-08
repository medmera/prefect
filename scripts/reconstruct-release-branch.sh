#!/bin/bash

# Script to reconstruct the release branch from a specific tag
# This script:
# 1. Fetches all remotes and tags
# 2. Identifies MMB-specific commits on the current release branch
# 3. Resets release branch to the specified tag
# 4. Cherry-picks the MMB-specific commits on top

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
UPSTREAM_REMOTE="upstream"
ORIGIN_REMOTE="origin"
MAIN_BRANCH="main"
RELEASE_BRANCH="release"

# Function to print colored output
print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if we're in a git repository
check_git_repo() {
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        print_error "Not in a git repository!"
        exit 1
    fi
}

# Function to check if remote exists
check_remote() {
    local remote=$1
    if ! git remote | grep -q "^${remote}$"; then
        print_error "Remote '${remote}' not found!"
        print_error "Please configure the ${remote} remote"
        exit 1
    fi
}

# Function to check if branch exists
check_branch() {
    local branch=$1
    if ! git show-ref --verify --quiet "refs/heads/${branch}"; then
        print_error "Branch '${branch}' not found!"
        exit 1
    fi
}

# Function to get current branch
get_current_branch() {
    git branch --show-current
}

# Function to check for uncommitted changes
check_clean_working_tree() {
    if ! git diff-index --quiet HEAD --; then
        print_error "You have uncommitted changes!"
        print_error "Please commit or stash your changes before running this script."
        echo ""
        print_error "Working tree status:"
        git status --porcelain
        exit 1
    fi
}

# Function to verify tag exists
check_tag_exists() {
    local tag=$1
    if ! git rev-parse "$tag" >/dev/null 2>&1; then
        print_error "Tag '${tag}' not found!"
        print_error "Available tags matching pattern:"
        git tag -l "${tag}*" | head -10
        exit 1
    fi
}

# Function to backup current state
backup_current_state() {
    local backup_branch="backup-before-reconstruct-$(date +%Y%m%d-%H%M%S)"
    
    print_step "Creating backup branch: ${backup_branch}"
    git branch "${backup_branch}"
    print_success "Backup created: ${backup_branch}"
    
    # Push backup branch to origin for safety
    print_step "Pushing backup branch to origin..."
    if git push "${ORIGIN_REMOTE}" "${backup_branch}" 2>/dev/null; then
        print_success "Backup branch pushed to origin: ${backup_branch}"
        echo "Remote backup available at: ${ORIGIN_REMOTE}/${backup_branch}"
    else
        print_warning "Failed to push backup branch to origin (continuing anyway)"
        echo "Local backup still available: ${backup_branch}"
    fi
    
    echo "If something goes wrong, you can restore with:"
    echo "  Local:  git checkout ${backup_branch}"
    echo "  Remote: git checkout ${ORIGIN_REMOTE}/${backup_branch} (if pushed)"
}

# Function to identify MMB-specific commits
identify_mmb_commits() {
    local base_tag=$1
    local current_release=$2
    
    print_step "Identifying MMB-specific commits between ${base_tag} and ${current_release}..."
    
    # Get commits that are on release but not on the tag
    local commits=$(git rev-list --reverse "${base_tag}..${current_release}" 2>/dev/null || echo "")
    
    if [ -z "$commits" ]; then
        print_warning "No commits found between ${base_tag} and ${current_release}"
        echo ""
        return 1
    fi
    
    echo "$commits"
    return 0
}

# Function to display commits for review
display_commits_for_review() {
    local base_tag=$1
    local commits_list=$2
    
    echo ""
    print_step "The following commits will be cherry-picked onto ${base_tag}:"
    echo ""
    
    local count=0
    while IFS= read -r commit_hash; do
        if [ -n "$commit_hash" ]; then
            count=$((count + 1))
            local commit_msg=$(git log --format=%s -n 1 "$commit_hash")
            local commit_author=$(git log --format="%an" -n 1 "$commit_hash")
            local commit_date=$(git log --format="%ar" -n 1 "$commit_hash")
            echo "  ${count}. ${commit_hash:0:10} - ${commit_msg}"
            echo "     Author: ${commit_author}, Date: ${commit_date}"
        fi
    done <<< "$commits_list"
    
    echo ""
    echo "Total: ${count} commit(s)"
    echo ""
}

# Main reconstruction function
reconstruct_release() {
    local base_tag=$1
    
    print_step "Starting release branch reconstruction..."
    echo "Target tag: ${base_tag}"
    echo ""
    
    # Perform pre-flight checks
    print_step "Performing pre-flight checks..."
    check_git_repo
    check_remote "$ORIGIN_REMOTE"
    check_branch "$RELEASE_BRANCH"
    check_clean_working_tree
    
    # Fetch all remotes and tags
    print_step "Fetching all remotes and tags..."
    git fetch --all --tags
    print_success "Fetched all remotes and tags"
    
    # Verify the tag exists
    check_tag_exists "$base_tag"
    
    # Get current branch for restoration later
    local original_branch=$(get_current_branch)
    print_step "Current branch: ${original_branch}"
    
    # Switch to release branch if not already on it
    if [ "$original_branch" != "$RELEASE_BRANCH" ]; then
        print_step "Switching to ${RELEASE_BRANCH} branch..."
        git checkout "$RELEASE_BRANCH"
    fi
    
    # Identify MMB-specific commits before we reset
    local current_release_commit=$(git rev-parse HEAD)
    local mmb_commits
    if mmb_commits=$(identify_mmb_commits "$base_tag" "$current_release_commit"); then
        display_commits_for_review "$base_tag" "$mmb_commits"
    else
        print_error "No commits to preserve. Aborting reconstruction."
        exit 1
    fi
    
    # Create backup before making changes
    backup_current_state
    
    # Reset release branch to the specified tag
    print_step "Resetting ${RELEASE_BRANCH} to ${base_tag}..."
    git reset --hard "$base_tag"
    print_success "Reset ${RELEASE_BRANCH} to ${base_tag}"
    
    # Cherry-pick the MMB-specific commits
    print_step "Cherry-picking MMB-specific commits..."
    local cherry_pick_success=true
    local commits_array=()
    
    # Convert newline-separated string to array
    while IFS= read -r commit; do
        if [ -n "$commit" ]; then
            commits_array+=("$commit")
        fi
    done <<< "$mmb_commits"
    
    # Cherry-pick all commits at once
    if [ ${#commits_array[@]} -gt 0 ]; then
        if git cherry-pick "${commits_array[@]}"; then
            print_success "Successfully cherry-picked ${#commits_array[@]} commit(s)"
        else
            print_error "Cherry-pick failed!"
            print_error "Please resolve conflicts manually, then run: git cherry-pick --continue"
            print_error "Or abort with: git cherry-pick --abort"
            print_error "After resolving, you can push manually with: git push origin ${RELEASE_BRANCH} --force"
            exit 1
        fi
    fi
    
    # Show the result
    echo ""
    print_step "Reconstruction complete. New branch structure:"
    echo ""
    git log --oneline -$((${#commits_array[@]} + 5)) | sed 's/^/  /'
    echo ""
    
    print_success "Release branch successfully reconstructed!"
    echo ""
    echo "Summary:"
    echo "  ✅ Base tag: ${base_tag}"
    echo "  ✅ MMB commits preserved: ${#commits_array[@]}"
    echo "  ✅ Current HEAD: $(git rev-parse --short HEAD)"
    echo ""
    echo "Next steps:"
    echo "  To push the reconstructed branch to origin:"
    echo "    git push origin ${RELEASE_BRANCH} --force"
    echo ""
    echo "  To verify the reconstruction:"
    echo "    git log ${base_tag}..${RELEASE_BRANCH}"
    echo ""
}

# Help function
show_help() {
    echo "Usage: $0 [OPTIONS] <tag>"
    echo ""
    echo "Reconstruct the release branch from a specific tag by:"
    echo "  1. Identifying all MMB-specific commits on current release branch"
    echo "  2. Resetting release branch to the specified tag"
    echo "  3. Cherry-picking the MMB-specific commits on top"
    echo ""
    echo "Arguments:"
    echo "  <tag>          Git tag to use as the base (e.g., 3.4.22, v1.2.3)"
    echo ""
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  --dry-run      Show what would be done without making changes"
    echo ""
    echo "Prerequisites:"
    echo "  - Clean working tree (no uncommitted changes)"
    echo "  - Release branch exists"
    echo "  - Origin remote configured"
    echo ""
    echo "This script will create a backup branch before making changes."
    echo ""
    echo "Examples:"
    echo "  $0 3.4.22              # Reconstruct from tag 3.4.22"
    echo "  $0 --dry-run 3.4.22    # Preview the reconstruction"
}

# Dry run function
dry_run() {
    local base_tag=$1
    
    print_step "DRY RUN - No changes will be made"
    echo ""
    echo "This script would reconstruct ${RELEASE_BRANCH} from tag: ${base_tag}"
    echo ""
    
    # Perform basic checks
    check_git_repo
    check_branch "$RELEASE_BRANCH"
    
    # Fetch to get latest tags
    print_step "Fetching tags..."
    git fetch --all --tags 2>/dev/null || true
    
    # Verify tag exists
    if ! git rev-parse "$base_tag" >/dev/null 2>&1; then
        print_error "Tag '${base_tag}' not found!"
        print_step "Available tags matching pattern:"
        git tag -l "${base_tag}*" | head -10
        exit 1
    fi
    
    local tag_commit=$(git rev-parse "$base_tag")
    echo "Tag '${base_tag}' points to commit: ${tag_commit:0:10}"
    echo ""
    
    # Show current status
    print_step "Current repository status:"
    echo "Current branch: $(get_current_branch)"
    echo "Current HEAD: $(git rev-parse --short HEAD)"
    echo ""
    
    # Identify what would be preserved
    local current_release_commit=$(git rev-parse "${RELEASE_BRANCH}")
    echo "Commits on ${RELEASE_BRANCH} that would be preserved:"
    
    local mmb_commits
    if mmb_commits=$(identify_mmb_commits "$base_tag" "$current_release_commit"); then
        display_commits_for_review "$base_tag" "$mmb_commits"
    else
        echo "  (none found)"
        echo ""
        print_warning "No commits to preserve - reconstruction would not make sense"
        exit 1
    fi
    
    echo "After reconstruction, the ${RELEASE_BRANCH} branch would have:"
    echo "  1. Base: commit from tag ${base_tag} (${tag_commit:0:10})"
    echo "  2. Plus: the MMB-specific commits listed above"
    echo ""
    echo "To proceed with the reconstruction, run without --dry-run:"
    echo "  $0 ${base_tag}"
}

# Parse command line arguments
DRY_RUN=false
BASE_TAG=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -*)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
        *)
            if [ -z "$BASE_TAG" ]; then
                BASE_TAG=$1
            else
                print_error "Too many arguments"
                show_help
                exit 1
            fi
            shift
            ;;
    esac
done

# Require tag argument
if [ -z "$BASE_TAG" ]; then
    print_error "Missing required argument: <tag>"
    echo ""
    show_help
    exit 1
fi

# Execute
if [ "$DRY_RUN" = true ]; then
    dry_run "$BASE_TAG"
else
    reconstruct_release "$BASE_TAG"
fi

