#!/bin/bash

set -euo pipefail

# Parse command line arguments
PROJECT_ID="$1"
REGION="$2"
REPO_NAME="$3"
BUILD_INTEGRATIONS="${4:-true}"
DRY_RUN="${5:-false}"
FORCE_RELEASE_VERSION="${6:-false}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Exit codes
EXIT_SUCCESS=0
EXIT_PARTIAL_FAILURE=1  # Some packages failed but script handled it gracefully
EXIT_CONFIG_ERROR=2     # Configuration or setup error
EXIT_CRITICAL_ERROR=3   # Unhandled crash or critical error

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" >&2
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2
    exit $EXIT_CRITICAL_ERROR
}

config_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] CONFIG ERROR:${NC} $1" >&2
    exit $EXIT_CONFIG_ERROR
}

success() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] SUCCESS:${NC} $1"
}

# Global cleanup tracking
declare -a BACKUP_FILES=()
declare -a TEMP_DIRS=()

# Cleanup function for emergency restoration
cleanup_on_exit() {
    local exit_code=$?
    
    # Check if we have any backups to restore
    if [[ "${#BACKUP_FILES[@]}" -gt 0 ]]; then
        warn "Script interrupted/failed - restoring original version files..."
        
        local i
        for i in "${!BACKUP_FILES[@]}"; do
            local backup_path="${BACKUP_FILES[$i]}"
            if [[ -f "$backup_path" ]]; then
                local original_path="${backup_path%.backup}"
                if mv "$backup_path" "$original_path" 2>/dev/null; then
                    log "Restored: $original_path"
                else
                    warn "Failed to restore: $original_path"
                fi
            fi
        done
    fi
    
    # Clean up temporary directories
    if [[ "${#TEMP_DIRS[@]}" -gt 0 ]]; then
        local i
        for i in "${!TEMP_DIRS[@]}"; do
            local temp_dir="${TEMP_DIRS[$i]}"
            if [[ -d "$temp_dir" ]]; then
                rm -rf "$temp_dir" 2>/dev/null
            fi
        done
    fi
    
    if [[ "${#BACKUP_FILES[@]}" -gt 0 || "${#TEMP_DIRS[@]}" -gt 0 ]]; then
        success "Cleanup completed"
    fi
    
    exit $exit_code
}

# Set up signal traps for cleanup
trap cleanup_on_exit EXIT INT TERM

# Track backup file for cleanup
track_backup() {
    local backup_path="$1"
    BACKUP_FILES+=("$backup_path")
}

# Track temp directory for cleanup
track_temp_dir() {
    local temp_dir="$1"
    TEMP_DIRS+=("$temp_dir")
}

# Remove from tracking when properly restored
untrack_backup() {
    local backup_path="$1"
    
    # Skip if BACKUP_FILES is empty
    if [[ ${#BACKUP_FILES[@]} -eq 0 ]]; then
        return 0
    fi
    
    local new_array=()
    for path in "${BACKUP_FILES[@]}"; do
        [[ "$path" != "$backup_path" ]] && new_array+=("$path")
    done
    if [[ ${#new_array[@]} -eq 0 ]]; then
        BACKUP_FILES=()
    else
        BACKUP_FILES=("${new_array[@]}")
    fi
}

# Remove from tracking when properly cleaned
untrack_temp_dir() {
    local temp_dir="$1"
    
    # Skip if TEMP_DIRS is empty
    if [[ ${#TEMP_DIRS[@]} -eq 0 ]]; then
        return 0
    fi
    
    local new_array=()
    for dir in "${TEMP_DIRS[@]}"; do
        [[ "$dir" != "$temp_dir" ]] && new_array+=("$dir")
    done
    if [[ ${#new_array[@]} -eq 0 ]]; then
        TEMP_DIRS=()
    else
        TEMP_DIRS=("${new_array[@]}")
    fi
}

# Validate required tools
check_requirements() {
    log "Checking requirements..."
    
    if ! command -v gcloud &> /dev/null; then
        config_error "gcloud CLI is required but not installed. Please install it first."
    fi
    
    if ! command -v uv &> /dev/null; then
        config_error "uv is required but not installed. Please install it first: https://docs.astral.sh/uv/"
    fi
    
    if ! command -v twine &> /dev/null; then
        warn "twine is not installed. Installing via uv..."
        uv tool install twine
    fi
    
    success "All requirements met."
}

# Build prefect-client package
build_prefect_client() {
    log "Building prefect-client package..."
    
    local tmpdir=$(mktemp -d)
    export TMPDIR="$tmpdir"
    
    log "Using workspace at $tmpdir"
    
    # Build the client package
    sh client/build_client.sh
    cd "$tmpdir"
    
    log "Building distributions..."
    uv build --sdist --wheel
    
    # Move distributions back to main directory
    mkdir -p "$PWD/../dist/client"
    mv dist/* "$PWD/../dist/client/"
    
    cd - > /dev/null
    rm -rf "$tmpdir"
    
    success "prefect-client package built successfully."
}

# Build prefect package
build_prefect() {
    log "Building prefect package..."
    
    # Clean any existing dist
    rm -rf dist/prefect
    mkdir -p dist/prefect
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY RUN: Would build prefect package with version $VERSION"
        return 0
    fi
    
    # Create clean version file for build
    local temp_build_info
    temp_build_info=$(create_temp_version_files "$VERSION")
    local original_build_info="src/prefect/_build_info.py"
    local backup_build_info="${original_build_info}.backup"
    
    # Also temporarily modify pyproject.toml to disable dynamic versioning
    local original_pyproject="pyproject.toml"
    local backup_pyproject="${original_pyproject}.backup"
    local temp_pyproject_dir
    temp_pyproject_dir=$(mktemp -d)
    track_temp_dir "$temp_pyproject_dir"
    local temp_pyproject_file="$temp_pyproject_dir/pyproject.toml"
    
    # Create modified pyproject.toml with static version
    sed 's|dynamic = \["version"\]|version = "'"$VERSION"'"|' "$original_pyproject" > "$temp_pyproject_file"
    
    # Backup and replace files
    if [[ -f "$original_build_info" ]]; then
        cp "$original_build_info" "$backup_build_info"
        track_backup "$backup_build_info"
    fi
    cp "$temp_build_info" "$original_build_info"
    
    cp "$original_pyproject" "$backup_pyproject"
    track_backup "$backup_pyproject"
    cp "$temp_pyproject_file" "$original_pyproject"
    
    log "Building distributions with clean version $VERSION..."
    if uv build --sdist --wheel --out-dir dist/prefect; then
        success "prefect package built successfully with version $VERSION"
        local build_success=true
    else
        warn "Failed to build prefect package"
        local build_success=false
    fi
    
    # Restore original files
    if [[ -f "$backup_build_info" ]]; then
        mv "$backup_build_info" "$original_build_info"
        untrack_backup "$backup_build_info"
    fi
    
    if [[ -f "$backup_pyproject" ]]; then
        mv "$backup_pyproject" "$original_pyproject"
        untrack_backup "$backup_pyproject"
    fi
    
    # Clean up temp files
    local temp_dir
    temp_dir=$(dirname "$temp_build_info")
    rm -rf "$temp_dir"
    untrack_temp_dir "$temp_dir"
    
    rm -rf "$temp_pyproject_dir"
    untrack_temp_dir "$temp_pyproject_dir"
    
    # Exit with error after cleanup if build failed
    if [[ "$build_success" != "true" ]]; then
        warn "Failed to build prefect package - this will be reported as a partial failure"
        return 1
    fi
}

# Discover integration packages
discover_integration_packages() {
    local packages=()
    for dir in src/integrations/prefect-*; do
        if [[ -d "$dir" && -f "$dir/pyproject.toml" ]]; then
            local package_name=$(basename "$dir")
            packages+=("$package_name")
        fi
    done
    
    if [[ ${#packages[@]} -eq 0 ]]; then
        return 1
    fi
    
    # Only output the package names (no logging)
    printf '%s\n' "${packages[@]}"
}

# Build integration packages
build_integration_packages() {
    log "Building integration packages..."
    
    local packages=()
    local package_list
    
    # Get the list of packages in a more portable way
    if package_list=$(discover_integration_packages 2>/dev/null); then
        while IFS= read -r package; do
            [[ -n "$package" ]] && packages+=("$package")
        done <<< "$package_list"
    fi
    
    if [[ ${#packages[@]} -eq 0 ]]; then
        warn "No integration packages found in src/integrations/"
        return 0
    fi
    
    log "Found ${#packages[@]} integration packages: ${packages[*]}"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY RUN: Integration package versions that would be used:"
        for package in "${packages[@]}"; do
            local tag_version
            tag_version=$(get_integration_tag_version "$package")
            if [[ -n "$tag_version" ]]; then
                log "  $package: $tag_version (from git tag)"
            else
                warn "  $package: no clean tag found, would use dynamic version"
            fi
        done
        return 0
    fi
    
    # Clean integration dist directory
    rm -rf dist/integrations
    mkdir -p dist/integrations
    
    local successful_builds=0
    local total_packages=${#packages[@]}
    
    for package in "${packages[@]}"; do
        local package_dir="src/integrations/$package"
        
        log "Building $package..."
        
        # Check if package directory exists
        if [[ ! -d "$package_dir" ]]; then
            warn "Package directory not found: $package_dir"
            continue
        fi
        
        # Get clean version for this integration
        local tag_version
        tag_version=$(get_integration_tag_version "$package")
        
        local temp_version_file=""
        local original_version_file=""
        local backup_version_file=""
        local temp_dir=""
        
        if [[ -n "$tag_version" ]]; then
            log "Using clean version $tag_version for $package"
            
            # Create clean version file for this integration
            temp_version_file=$(create_temp_integration_version_file "$package" "$tag_version")
            local module_name="${package//-/_}"  # Convert hyphens to underscores for Python module name
            original_version_file="$package_dir/$module_name/_version.py"
            backup_version_file="${original_version_file}.backup"
            temp_dir=$(dirname "$temp_version_file")
            
            # Backup and replace version file
            if [[ -f "$original_version_file" ]]; then
                cp "$original_version_file" "$backup_version_file"
                track_backup "$backup_version_file"
            fi
            cp "$temp_version_file" "$original_version_file"
        else
            warn "No clean tag found for $package, using dynamic version"
        fi
        
        # Clean existing dist in package directory
        rm -rf "$package_dir/dist"
        
        # Build the package using uv build (setuptools_scm for integrations)
        local build_success=false
        if (cd "$package_dir" && SETUPTOOLS_SCM_PRETEND_VERSION="${tag_version:-}" uv build --wheel --sdist); then
            # Move distributions to our main dist directory
            local package_dist_dir="dist/integrations/$package"
            mkdir -p "$package_dist_dir"
            mv "$package_dir/dist"/* "$package_dist_dir/"
            
            successful_builds=$((successful_builds + 1))
            success "Built $package successfully with version ${tag_version:-dynamic}"
            build_success=true
        else
            warn "Failed to build $package - continuing with next package"
        fi
        
        # Always restore original version file if we backed it up
        if [[ -f "$backup_version_file" ]]; then
            mv "$backup_version_file" "$original_version_file"
            untrack_backup "$backup_version_file"
        fi
        
        # Always clean up temp file
        if [[ -n "$temp_dir" ]]; then
            rm -rf "$temp_dir"
            untrack_temp_dir "$temp_dir"
        fi
    done
    
    log "Integration build summary: $successful_builds/$total_packages packages built successfully"
    
    if [[ $successful_builds -eq 0 ]]; then
        warn "No integration packages were built successfully"
        return 1
    fi
    
    success "Integration packages built successfully."
}

# Upload integration packages to GCP Artifact Registry
upload_integration_packages() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY RUN: Would upload integration packages from dist/integrations/"
        local package_count=0
        for package_dir in dist/integrations/*/; do
            if [[ -d "$package_dir" ]]; then
                local package_name=$(basename "$package_dir")
                local files
                files=$(find "$package_dir" -name "*.whl" -o -name "*.tar.gz" 2>/dev/null | wc -l)
                log "  $package_name: $files distribution files"
                package_count=$((package_count + 1))
            fi
        done
        log "Total integration packages to upload: $package_count"
        return 0
    fi
    
    log "Uploading integration packages to GCP Artifact Registry..."
    
    local repo_url="https://${REGION}-python.pkg.dev/${PROJECT_ID}/${REPO_NAME}/"
    local uploaded_count=0
    local failed_count=0
    local total_count=0
    
    for package_dir in dist/integrations/*/; do
        if [[ -d "$package_dir" && $(ls -A "$package_dir" 2>/dev/null) ]]; then
            local package_name=$(basename "$package_dir")
            total_count=$((total_count + 1))
            
            log "Uploading $package_name..."
            
            # Upload using twine with error handling
            if twine upload \
                --repository-url "$repo_url" \
                --username oauth2accesstoken \
                --password "$(gcloud auth print-access-token)" \
                "$package_dir"/* 2>&1; then
                
                uploaded_count=$((uploaded_count + 1))
                success "$package_name uploaded successfully"
            else
                failed_count=$((failed_count + 1))
                warn "Failed to upload $package_name - continuing with next package"
            fi
        fi
    done
    
    # Always show summary, even if some failed
    log "Integration upload summary: $uploaded_count/$total_count packages uploaded successfully"
    if [[ $failed_count -gt 0 ]]; then
        warn "$failed_count integration packages failed to upload"
    fi
    
    if [[ $uploaded_count -eq 0 ]]; then
        warn "No integration packages were uploaded"
        return 1
    fi
    
    success "Integration package upload completed with $uploaded_count successes."
    return 0
}

# Upload packages to GCP Artifact Registry
upload_packages() {
    local package_type="$1"
    local dist_dir="$2"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY RUN: Would upload $package_type packages from $dist_dir"
        if [[ -d "$dist_dir" ]]; then
            local files
            files=$(find "$dist_dir" -name "*.whl" -o -name "*.tar.gz" 2>/dev/null | wc -l)
            log "  Found $files distribution files to upload"
        else
            warn "  Distribution directory $dist_dir does not exist"
        fi
        return 0
    fi
    
    log "Uploading $package_type packages to GCP Artifact Registry..."
    
    local repo_url="https://${REGION}-python.pkg.dev/${PROJECT_ID}/${REPO_NAME}/"
    
    # Upload using twine with error handling
    if twine upload \
        --repository-url "$repo_url" \
        --username oauth2accesstoken \
        --password "$(gcloud auth print-access-token)" \
        "$dist_dir"/* 2>&1; then
        
        success "$package_type packages uploaded successfully."
        return 0
    else
        warn "Failed to upload $package_type packages - continuing with other uploads"
        return 1
    fi
}

# Get latest tag for prefect core (x.x.x or x.x.x.anything or x.x.xanything format) by creation date
get_prefect_tag_version() {
    if [[ "$FORCE_RELEASE_VERSION" == "true" ]]; then
        git tag --list --sort=-creatordate | grep -E "^[0-9]+\.[0-9]+\.[0-9]+$" 2>/dev/null | head -1
    else
        git tag --list --sort=-creatordate | grep -E "^[0-9]+\.[0-9]+\.[0-9]+([.]?[a-zA-Z0-9]+)*$" 2>/dev/null | head -1
    fi
}

# Get latest tag for integration package (prefect-{name}-x.x.x or prefect-{name}-x.x.x.anything format) by creation date
get_integration_tag_version() {
    local package_name="$1"
    if [[ "$FORCE_RELEASE_VERSION" == "true" ]]; then
        git tag --list --sort=-creatordate | grep -E "^${package_name}-[0-9]+\.[0-9]+\.[0-9]+$" 2>/dev/null | head -1 | sed "s/^${package_name}-//"
    else
        git tag --list --sort=-creatordate | grep -E "^${package_name}-[0-9]+\.[0-9]+\.[0-9]+([.]?[a-zA-Z0-9]+)*$" 2>/dev/null | head -1 | sed "s/^${package_name}-//"
    fi
}

# Create clean version files temporarily
create_temp_version_files() {
    local version="$1"
    local temp_build_info_dir="$(mktemp -d)"
    local temp_build_info_file="$temp_build_info_dir/_build_info.py"
    
    # Track temp directory for cleanup
    track_temp_dir "$temp_build_info_dir"
    
    # Create clean _build_info.py
    cat > "$temp_build_info_file" << EOF
# Generated for clean release
__version__ = "$version"
__build_date__ = "$(date -u +"%Y-%m-%d %H:%M:%S.000000+00:00")"
__git_commit__ = "$(git rev-parse HEAD)"
__dirty__ = False
EOF
    
    echo "$temp_build_info_file"
}

# Create clean integration version file
create_temp_integration_version_file() {
    local package_name="$1"
    local version="$2"
    local temp_version_dir="$(mktemp -d)"
    local temp_version_file="$temp_version_dir/_version.py"
    
    # Track temp directory for cleanup
    track_temp_dir "$temp_version_dir"
    
    # Parse version into components
    local major minor patch dev_part
    if [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(.*)$ ]]; then
        major="${BASH_REMATCH[1]}"
        minor="${BASH_REMATCH[2]}"
        patch="${BASH_REMATCH[3]}"
        dev_part="${BASH_REMATCH[4]}"
    else
        major="0"
        minor="0"
        patch="0"
        dev_part=""
    fi
    
    # Create clean _version.py
    cat > "$temp_version_file" << EOF
# file generated for clean release
# don't change, don't track in version control

__all__ = ["__version__", "__version_tuple__", "version", "version_tuple"]

TYPE_CHECKING = False
if TYPE_CHECKING:
    from typing import Tuple
    from typing import Union

    VERSION_TUPLE = Tuple[Union[int, str], ...]
else:
    VERSION_TUPLE = object

version: str
__version__: str
__version_tuple__: VERSION_TUPLE
version_tuple: VERSION_TUPLE

__version__ = version = '$version'
__version_tuple__ = version_tuple = ($major, $minor, $patch${dev_part:+, '$dev_part'})
EOF
    
    echo "$temp_version_file"
}

# Get current version (original function, now with tag-based override)
get_version() {
    local tag_version
    tag_version=$(get_prefect_tag_version)
    if [[ -n "$tag_version" ]]; then
        echo "$tag_version"
    else
        if [[ "$FORCE_RELEASE_VERSION" == "true" ]]; then
            config_error "No clean release version tag (x.y.z) found. Please create a tag matching x.y.z before running this script with FORCE_RELEASE_VERSION=true."
        else
            config_error "No clean version tag found. Please create a tag matching x.y.z or x.y.z.suffix before running this script."
        fi
    fi
}

# Main execution
main() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log "=== DRY RUN MODE - No actual building or uploading will occur ==="
    fi
    
    log "Starting Prefect Python package release to GCP Artifact Registry"
    log "Project ID: $PROJECT_ID"
    log "Region: $REGION"
    log "Repository: $REPO_NAME"
    log "Build integrations: $BUILD_INTEGRATIONS"
    log "Dry run: $DRY_RUN"
    
    # Get version
    VERSION=$(get_version)
    log "Package version: $VERSION"
    
    if [[ "$DRY_RUN" != "true" ]]; then
        check_requirements
        
        # Clean dist directory
        rm -rf dist
        mkdir -p dist
    else
        log "DRY RUN: Skipping requirements check"
    fi
    
    # Build packages
    # build_prefect_client
    local build_success=true
    if ! build_prefect; then
        build_success=false
        warn "Prefect package build failed"
    fi
    
    # Build integration packages if requested
    if [[ "$BUILD_INTEGRATIONS" == "true" ]]; then
        if build_integration_packages; then
            log "Integration packages built successfully"
        else
            if [[ "$DRY_RUN" == "true" ]]; then
                warn "Some integration packages would fail to build"
            else
                warn "Some integration packages failed to build, continuing with upload..."
            fi
        fi
    else
        log "Skipping integration packages (BUILD_INTEGRATIONS=false)"
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "=== DRY RUN SUMMARY ==="
        log "Prefect version: $VERSION"
        log "Would upload to: https://${REGION}-python.pkg.dev/${PROJECT_ID}/${REPO_NAME}/"
        success "Dry run completed - versions validated!"
        return 0
    fi
    
    # Upload packages - track results
    local upload_results=()
    local total_upload_attempts=0
    local successful_uploads=0
    
    # Upload prefect package
    if [[ "$build_success" == "true" ]]; then
        total_upload_attempts=$((total_upload_attempts + 1))
        if upload_packages "prefect" "dist/prefect"; then
            upload_results+=("✓ prefect package uploaded successfully")
            successful_uploads=$((successful_uploads + 1))
        else
            upload_results+=("✗ prefect package upload failed")
        fi
    else
        upload_results+=("✗ prefect package skipped (build failed)")
    fi
    
    # Upload integration packages if they were built
    if [[ "$BUILD_INTEGRATIONS" == "true" && -d "dist/integrations" ]]; then
        total_upload_attempts=$((total_upload_attempts + 1))
        if upload_integration_packages; then
            upload_results+=("✓ integration packages uploaded successfully")
            successful_uploads=$((successful_uploads + 1))
        else
            upload_results+=("✗ some integration packages failed to upload")
        fi
    fi
    
    # Show upload summary
    echo ""
    log "=== UPLOAD SUMMARY ==="
    for result in "${upload_results[@]}"; do
        if [[ "$result" == ✓* ]]; then
            success "$result"
        else
            warn "$result"
        fi
    done
    
    log "Upload completion: $successful_uploads/$total_upload_attempts upload groups completed successfully"
    
    if [[ $successful_uploads -eq $total_upload_attempts ]]; then
        success "All packages released successfully!"
        exit $EXIT_SUCCESS
    elif [[ $successful_uploads -gt 0 ]]; then
        warn "Partial success - some packages were uploaded, but others failed"
        warn "This is considered a partial failure but the script handled it gracefully"
        exit $EXIT_PARTIAL_FAILURE
    else
        warn "No packages were uploaded successfully"
        warn "This is considered a partial failure but the script handled it gracefully"
        exit $EXIT_PARTIAL_FAILURE
    fi
    log "Repository URL: https://console.cloud.google.com/artifacts/browse/${PROJECT_ID}/${REGION}/${REPO_NAME}"
    
    # Installation instructions
    echo ""
    log "To install the packages from your registry:"
    echo "pip install --index-url https://${REGION}-python.pkg.dev/${PROJECT_ID}/${REPO_NAME}/simple/ prefect"
    echo "pip install --index-url https://${REGION}-python.pkg.dev/${PROJECT_ID}/${REPO_NAME}/simple/ prefect-client"
    
    if [[ "$BUILD_INTEGRATIONS" == "true" && -d "dist/integrations" ]]; then
        echo ""
        log "Integration packages are also available:"
        for package_dir in dist/integrations/*/; do
            if [[ -d "$package_dir" ]]; then
                local package_name=$(basename "$package_dir")
                echo "pip install --index-url https://${REGION}-python.pkg.dev/${PROJECT_ID}/${REPO_NAME}/simple/ $package_name"
            fi
        done
    fi
}

# Show usage if help is requested
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Usage: $0 [PROJECT_ID] [REGION] [REPO_NAME] [BUILD_INTEGRATIONS] [DRY_RUN] [FORCE_RELEASE_VERSION]"
    echo ""
    echo "Build and publish Prefect Python packages to GCP Artifact Registry"
    echo "Uses clean git tag versions instead of dirty development versions"
    echo ""
    echo "Arguments:"
    echo "  PROJECT_ID          GCP project ID (required)"
    echo "  REGION              GCP region (required, e.g., us-central1, us-west1, europe-west1)"
    echo "  REPO_NAME           Repository name (required)"
    echo "  BUILD_INTEGRATIONS  Build integration packages (optional, default: 'true', set to 'false' to skip)"
    echo "  DRY_RUN             Preview versions without building/uploading (optional, default: 'false', set to 'true' for dry run)"
    echo "  FORCE_RELEASE_VERSION  Only allow x.y.z tags (no suffixes) for version (optional, default: 'false', set to 'true' to require strict release version)"
    echo ""
    echo "Version handling:"
    echo "  - If FORCE_RELEASE_VERSION=true: Only tags matching x.y.z (e.g., 3.4.11) are allowed."
    echo "  - Otherwise: Allows x.y.z or x.y.z.suffix (e.g., 3.4.11.dev1)"
    echo "  - Integrations: Uses latest tag matching prefect-{name}-x.x.x pattern if FORCE_RELEASE_VERSION, else allows suffixes."
    echo "  - Falls back to dynamic version if no clean tag found (unless FORCE_RELEASE_VERSION=true)"
    echo ""
    echo "Examples:"
    echo "  $0 my-project us-central1 prefect-pypi                  # Basic usage"
    echo "  $0 my-project us-west1 my-pypi-repo                     # Custom region/repo"
    echo "  $0 my-project us-west1 my-pypi-repo false               # Skip integration packages"
    echo "  $0 my-project us-west1 my-pypi-repo true true           # Dry run with integrations"
    echo "  $0 my-project us-central1 prefect-pypi false false      # Core only, actual build"
    exit 0
fi

# Validate required arguments
if [[ -z "$PROJECT_ID" ]]; then
    config_error "PROJECT_ID is required as the first argument"
fi

if [[ -z "$REGION" ]]; then
    config_error "REGION is required as the second argument"
fi

if [[ -z "$REPO_NAME" ]]; then
    config_error "REPO_NAME is required as the third argument"
fi

main "$@"
main "$@"