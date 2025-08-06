#!/bin/bash

# Script to sync changes from upstream into the release branch
# This script:
# 1. Syncs the main branch from upstream (original repo)
# 2. Rebases the release branch onto the updated main branch

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
MAIN_BRANCH_ORIGIN="main"
MAIN_BRANCH_UPSTREAM="main"
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
        print_error "Please configure the upstream remote: git remote add ${remote} <upstream-repo-url>"
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

# Function to ensure required branches exist locally
setup_required_branches() {
    local current_branch=$(get_current_branch)
    
    # Ensure main-tracking branch exists locally
    if ! git show-ref --verify --quiet "refs/heads/${MAIN_BRANCH_ORIGIN}"; then
        print_step "Local ${MAIN_BRANCH_ORIGIN} branch not found. Fetching from origin..."
        
        # Fetch only the main-tracking branch from origin
        if git fetch "${ORIGIN_REMOTE}" "${MAIN_BRANCH_ORIGIN}:${MAIN_BRANCH_ORIGIN}" 2>/dev/null; then
            print_success "Fetched and created local ${MAIN_BRANCH_ORIGIN} branch from ${ORIGIN_REMOTE}"
        elif git show-ref --verify --quiet "refs/remotes/${ORIGIN_REMOTE}/${MAIN_BRANCH_ORIGIN}"; then
            # Fallback: if remote ref already exists, create branch from it
            print_step "Creating local ${MAIN_BRANCH_ORIGIN} branch from existing remote..."
            git checkout -b "${MAIN_BRANCH_ORIGIN}" "${ORIGIN_REMOTE}/${MAIN_BRANCH_ORIGIN}"
            git checkout "${current_branch}"
            print_success "Created local ${MAIN_BRANCH_ORIGIN} branch"
        else
            print_error "Could not find or fetch ${MAIN_BRANCH_ORIGIN} branch from ${ORIGIN_REMOTE}!"
            print_error "Please ensure the ${MAIN_BRANCH_ORIGIN} branch exists in your origin remote."
            exit 1
        fi
    else
        print_step "Local ${MAIN_BRANCH_ORIGIN} branch already exists"
    fi
    
    # Ensure we can access upstream main branch (fetch only if needed)
    if ! git show-ref --verify --quiet "refs/remotes/${UPSTREAM_REMOTE}/${MAIN_BRANCH_UPSTREAM}"; then
        print_step "Upstream ${MAIN_BRANCH_UPSTREAM} branch not found locally. Fetching from upstream..."
        if git fetch "${UPSTREAM_REMOTE}" "${MAIN_BRANCH_UPSTREAM}" 2>/dev/null; then
            print_success "Fetched ${MAIN_BRANCH_UPSTREAM} branch from ${UPSTREAM_REMOTE}"
        else
            print_error "Could not fetch ${MAIN_BRANCH_UPSTREAM} branch from ${UPSTREAM_REMOTE}!"
            print_error "Please check your upstream remote configuration."
            exit 1
        fi
    else
        print_step "Upstream ${MAIN_BRANCH_UPSTREAM} branch reference already exists"
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
        echo ""
        print_error "Detailed diff of changes:"
        git diff --name-status
        echo ""
        print_error "Full diff:"
        git diff
        exit 1
    fi
}

# Function to backup current state
backup_current_state() {
    local current_branch=$(get_current_branch)
    local backup_branch="backup-before-sync-$(date +%Y%m%d-%H%M%S)"
    
    print_step "Creating backup branch: ${backup_branch}"
    git branch "${backup_branch}"
    print_success "Backup created: ${backup_branch}"
    
    # Push backup branch to origin for safety
    print_step "Pushing backup branch to origin..."
    if git push "${ORIGIN_REMOTE}" "${backup_branch}"; then
        print_success "Backup branch pushed to origin: ${backup_branch}"
        echo "Remote backup available at: ${ORIGIN_REMOTE}/${backup_branch}"
    else
        print_warning "Failed to push backup branch to origin (continuing anyway)"
        echo "Local backup still available: ${backup_branch}"
    fi
    
    echo "If something goes wrong, you can restore with:"
    echo "  Local:  git checkout ${backup_branch}"
    echo "  Remote: git checkout ${ORIGIN_REMOTE}/${backup_branch}"
}

# Main sync function
sync_upstream() {
    print_step "Starting upstream sync process..."
    
    # Perform pre-flight checks
    print_step "Performing pre-flight checks..."
    check_git_repo
    check_remote "$UPSTREAM_REMOTE"
    check_remote "$ORIGIN_REMOTE"
    check_branch "$RELEASE_BRANCH"
    check_clean_working_tree
    
    # Get current branch for restoration later
    local original_branch=$(get_current_branch)
    print_step "Current branch: ${original_branch}"
    
    # Setup required branches (fetch only what we need)
    setup_required_branches
    
    # Create backup
    backup_current_state
    
    # Fetch latest changes for main branch and tags from upstream
    print_step "Fetching latest ${MAIN_BRANCH_UPSTREAM} and tags from upstream..."
    git fetch "$UPSTREAM_REMOTE" "$MAIN_BRANCH_UPSTREAM" --tags
    print_success "Fetched latest ${MAIN_BRANCH_UPSTREAM} and tags from upstream"
    
    # Switch to main branch
    print_step "Switching to ${MAIN_BRANCH_ORIGIN} branch..."
    git checkout "$MAIN_BRANCH_ORIGIN"
    
    # Merge upstream changes into main
    print_step "Merging upstream/${MAIN_BRANCH_UPSTREAM} into local ${MAIN_BRANCH_ORIGIN}..."
    if git merge "${UPSTREAM_REMOTE}/${MAIN_BRANCH_UPSTREAM}" --ff-only; then
        print_success "Successfully fast-forwarded ${MAIN_BRANCH_ORIGIN}"
    else
        print_error "Cannot fast-forward ${MAIN_BRANCH_ORIGIN}!"
        print_error "This might mean you have local commits on ${MAIN_BRANCH_ORIGIN}."
        print_error "Consider using: git reset --hard ${UPSTREAM_REMOTE}/${MAIN_BRANCH_UPSTREAM}"
        exit 1
    fi
    
    # Push updated main to origin
    print_step "Pushing updated ${MAIN_BRANCH_ORIGIN} to origin..."
    git push "$ORIGIN_REMOTE" "$MAIN_BRANCH_ORIGIN"
    print_success "Pushed ${MAIN_BRANCH_ORIGIN} to origin"

    # Switch to release branch
    print_step "Switching to ${RELEASE_BRANCH} branch..."
    git checkout "$RELEASE_BRANCH"
    
    # Check if there are any commits on release that aren't on main
    local commits_ahead=$(git rev-list --count "${MAIN_BRANCH_ORIGIN}..${RELEASE_BRANCH}")
    
    if [ "$commits_ahead" -eq 0 ]; then
        print_warning "No custom commits found on ${RELEASE_BRANCH}."
        print_step "Fast-forwarding ${RELEASE_BRANCH} to match ${MAIN_BRANCH_ORIGIN}..."
        git merge "$MAIN_BRANCH_ORIGIN" --ff-only
    else
        print_step "Found ${commits_ahead} custom commit(s) on ${RELEASE_BRANCH}."
        print_step "Rebasing ${RELEASE_BRANCH} onto updated ${MAIN_BRANCH_ORIGIN}..."
        
        if git rebase "$MAIN_BRANCH_ORIGIN"; then
            print_success "Successfully rebased ${RELEASE_BRANCH} onto ${MAIN_BRANCH_ORIGIN}"
        else
            print_error "Rebase failed! Please resolve conflicts manually."
            print_error "After resolving conflicts, run: git rebase --continue"
            print_error "Or abort the rebase with: git rebase --abort"
            exit 1
        fi
    fi
    
    # Push updated release branch to origin
    print_step "Pushing updated ${RELEASE_BRANCH} to origin..."
    if [ "$commits_ahead" -gt 0 ]; then
        # Force push needed after rebase
        print_warning "Force pushing ${RELEASE_BRANCH} (required after rebase)..."
        git push "$ORIGIN_REMOTE" "$RELEASE_BRANCH" --force-with-lease
    else
        git push "$ORIGIN_REMOTE" "$RELEASE_BRANCH"
    fi
    print_success "Pushed ${RELEASE_BRANCH} to origin"

    # Push all tags to origin   
    print_step "Pushing all tags to origin..."
    git push "$ORIGIN_REMOTE" --tags
    print_success "Pushed all tags to origin"
    
    # Return to original branch if it wasn't release
    if [ "$original_branch" != "$RELEASE_BRANCH" ]; then
        print_step "Returning to original branch: ${original_branch}"
        git checkout "$original_branch"
    fi
    
    print_success "Sync completed successfully!"
    echo ""
    echo "Summary:"
    echo "  ✅ Synced ${MAIN_BRANCH_ORIGIN} with upstream/${MAIN_BRANCH_UPSTREAM}"
    echo "  ✅ Synced all tags from upstream to origin"
    echo "  ✅ Rebased ${RELEASE_BRANCH} onto updated ${MAIN_BRANCH_ORIGIN}"
    echo "  ✅ Pushed changes to origin"
    echo ""
    echo "Your ${RELEASE_BRANCH} branch now contains the latest upstream changes"
    echo "with your custom changes rebased on top, and all upstream tags are available."
}

# Help function
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Sync upstream changes into the release branch by:"
    echo "  1. Fetching from upstream (including tags)"
    echo "  2. Fast-forwarding ${MAIN_BRANCH_ORIGIN} branch with upstream/${MAIN_BRANCH_UPSTREAM} changes"
    echo "  3. Syncing all tags from upstream to origin"
    echo "  4. Rebasing ${RELEASE_BRANCH} branch onto updated ${MAIN_BRANCH_ORIGIN}"
    echo ""
    echo "Options:"
    echo "  -h, --help     Show this help message"
    echo "  --dry-run      Show what would be done without making changes"
    echo ""
    echo "Prerequisites:"
    echo "  - Clean working tree (no uncommitted changes)"
    echo "  - Upstream remote configured"
    echo "  - Both '${MAIN_BRANCH_ORIGIN}' and '${RELEASE_BRANCH}' branches exist"
    echo ""
    echo "This script will create a backup branch before making changes."
}

# Dry run function
dry_run() {
    print_step "DRY RUN - No changes will be made"
    echo ""
    echo "This script would:"
    echo "  1. Create a backup branch"
    echo "  2. Fetch from upstream remote (including tags)"
    echo "  3. Push all tags from upstream to origin"
    echo "  4. Fast-forward ${MAIN_BRANCH_ORIGIN} with upstream/${MAIN_BRANCH_UPSTREAM}"
    echo "  5. Push updated ${MAIN_BRANCH_ORIGIN} to origin"
    echo "  6. Rebase ${RELEASE_BRANCH} onto updated ${MAIN_BRANCH_ORIGIN}"
    echo "  7. Push updated ${RELEASE_BRANCH} to origin"
    echo ""
    
    # Show current status
    print_step "Current repository status:"
    echo "Current branch: $(get_current_branch)"
    echo "Remotes configured:"
    git remote -v | sed 's/^/  /'
    echo ""
    echo "Commits on ${RELEASE_BRANCH} not on ${MAIN_BRANCH_ORIGIN}:"
    local commits_ahead=$(git rev-list --count "${MAIN_BRANCH_ORIGIN}..${RELEASE_BRANCH}" 2>/dev/null || echo "0")
    if [ "$commits_ahead" -gt 0 ]; then
        git log --oneline "${MAIN_BRANCH_ORIGIN}..${RELEASE_BRANCH}" | sed 's/^/  /'
    else
        echo "  (none)"
    fi
}

# Parse command line arguments
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    --dry-run)
        dry_run
        exit 0
        ;;
    "")
        sync_upstream
        ;;
    *)
        print_error "Unknown option: $1"
        show_help
        exit 1
        ;;
esac