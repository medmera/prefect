#!/bin/bash

set -euo pipefail

# Parse command line arguments
PROJECT_ID="$1"
REGION="$2"
REPO_NAME="$3"
DRY_RUN="${4:-false}"
NO_PUSH="${5:-false}"
FORCE_RELEASE_VERSION="${6:-false}"
SINGLE_PYTHON_VERSION="${7:-}"
IMAGE_TYPE="${8:-}"

# Docker build configuration
PYTHON_VERSIONS=("3.9" "3.10" "3.11" "3.12" "3.13")
FLAVORS=("")
IMAGES=("prefect")
PLATFORMS="linux/amd64,linux/arm64"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global cleanup tracking
declare -a BACKUP_FILES=()
declare -a TEMP_DIRS=()

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" >&2
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING:${NC} $1" >&2
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $1" >&2
    exit 1
}

success() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] SUCCESS:${NC} $1" >&2
}

# Cleanup function for emergency restoration
cleanup_on_exit() {
    local exit_code=$?
    
    # Check if we have any backups to restore
    if [[ "${#BACKUP_FILES[@]}" -gt 0 ]]; then
        warn "Script interrupted/failed - restoring original files..."
        
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
        error "gcloud CLI is required but not installed. Please install it first."
    fi
    
    if ! command -v docker &> /dev/null; then
        error "Docker is required but not installed. Please install it first."
    fi
    
    # Check if docker buildx is available
    if ! docker buildx version &> /dev/null; then
        error "Docker buildx is required but not available. Please install/enable it."
    fi
    
    success "All requirements met."
}

# Authenticate with GCP
authenticate_gcp() {
    log "Authenticating with GCP..."
    
    # Check if already authenticated
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q .; then
        log "No active GCP authentication found. Please authenticate:"
        gcloud auth login
    fi
    
    # Set project
    gcloud config set project "$PROJECT_ID"
    
    # Configure authentication for artifact registry
    gcloud auth configure-docker "${REGION}-docker.pkg.dev"
    
    success "GCP authentication configured."
}

# Create repository if it doesn't exist
create_repository() {
    log "Checking if repository exists..."
    
    if ! gcloud artifacts repositories describe "$REPO_NAME" --location="$REGION" &> /dev/null; then
        log "Creating Docker repository: $REPO_NAME"
        gcloud artifacts repositories create "$REPO_NAME" \
            --repository-format=docker \
            --location="$REGION" \
            --description="Prefect Docker images"
    else
        log "Repository $REPO_NAME already exists."
    fi
    
    success "Repository ready."
}

# Setup Docker buildx
setup_buildx() {
    log "Setting up Docker buildx..."
    
    # Create buildx builder if it doesn't exist
    if ! docker buildx inspect prefect-builder &> /dev/null; then
        docker buildx create --name prefect-builder --use
    else
        docker buildx use prefect-builder
    fi
    
    # Bootstrap the builder
    docker buildx inspect --bootstrap
    
    success "Docker buildx ready."
}

# Get latest tag for prefect core (x.x.x or x.x.x.anything or x.x.xanything format) by creation date
get_prefect_tag_version() {
    if [[ "$FORCE_RELEASE_VERSION" == "true" ]]; then
        git tag --list --sort=-creatordate | grep -E "^[0-9]+\.[0-9]+\.[0-9]+$" 2>/dev/null | head -1
    else
        git tag --list --sort=-creatordate | grep -E "^[0-9]+\.[0-9]+\.[0-9]+([.]?[a-zA-Z0-9]+)*$" 2>/dev/null | head -1
    fi
}

# Create clean version files temporarily (same as Python script)
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

# Get current version (original function, now with tag-based override)
get_version() {
    local tag_version
    tag_version=$(get_prefect_tag_version)
    if [[ -n "$tag_version" ]]; then
        echo "$tag_version"
    else
        if [[ "$FORCE_RELEASE_VERSION" == "true" ]]; then
            error "No clean release version tag (x.y.z) found. Please create a tag matching x.y.z before running this script with FORCE_RELEASE_VERSION=true."
        else
            config_error "No clean version tag found. Please create a tag matching x.y.z or x.y.z.suffix before running this script."
        fi
    fi
}

# Generate tags for an image
generate_tags() {
    local image="$1"
    local python_version="$2"
    local flavor="$3"
    
    # Validate required variables
    if [[ -z "$PROJECT_ID" ]]; then
        error "PROJECT_ID is empty. Please provide it as the first argument."
    fi
    if [[ -z "$REGION" ]]; then
        error "REGION is empty. Please provide it as the second argument."
    fi
    if [[ -z "$REPO_NAME" ]]; then
        error "REPO_NAME is empty. Please provide it as the third argument."
    fi
    if [[ -z "$PREFECT_VERSION" ]]; then
        error "PREFECT_VERSION is empty. Make sure get_versions() was called successfully."
    fi
    if [[ -z "$image" ]]; then
        error "Image name is empty."
    fi
    if [[ -z "$python_version" ]]; then
        error "Python version is empty."
    fi
    
    local base_name="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${image}"
    log "Generating tags with base: $base_name"
    
    local tags=()
    
    # Build base tag
    local tag="${PREFECT_VERSION}-python${python_version}${flavor}"
    # Append image type at the end when provided (e.g., 3.4.12.dev2-python3.12-poetry-gcloud)
    if [[ -n "$IMAGE_TYPE" ]]; then
        tag+="-${IMAGE_TYPE}"
    fi
    
    # Version-specific tag
    tags+=("${base_name}:${tag}")
    
    printf '%s\n' "${tags[@]}"
}

# Build and push single image
build_and_push_image() {
    local image="$1"
    local python_version="$2"
    local flavor="$3"
    
    log "Building $image:python$python_version$flavor..."
    
    # Skip incompatible combinations
    if [[ "$image" == "prefect-client" && ("$flavor" == "-conda" || "$flavor" == "-kubernetes") ]]; then
        log "Skipping incompatible combination: $image$flavor"
        return 0
    fi
    
    # Determine Dockerfile and build args
    local dockerfile
    local build_args=()
    
    if [[ "$image" == "prefect-client" ]]; then
        dockerfile="client/Dockerfile"
    else
        if [[ -n "$IMAGE_TYPE" ]]; then
            dockerfile="Dockerfile.${IMAGE_TYPE}"
        else
            dockerfile="Dockerfile"
        fi
    fi
    
    build_args+=("--build-arg" "PYTHON_VERSION=$python_version")
    
    if [[ "$flavor" == "-conda" ]]; then
        build_args+=("--build-arg" "BASE_IMAGE=prefect-conda")
    elif [[ "$flavor" == "-kubernetes" ]]; then
        build_args+=("--build-arg" "PREFECT_EXTRAS=[redis,kubernetes,iap-auth]")
    else
        # Default build includes iap-auth for GCP compatibility
        build_args+=("--build-arg" "PREFECT_EXTRAS=[redis,client,otel,iap-auth]")
    fi
    
    # Generate tags early so they can be printed in dry-run
    local tags
    IFS=$'\n' read -r -d '' -a tags < <(generate_tags "$image" "$python_version" "$flavor" && printf '\0')
    
    log "Using Dockerfile: $dockerfile"
    log "Full image tag(s):"
    for tag in "${tags[@]}"; do
        log "  - $tag"
    done
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY RUN: Would build $image:python$python_version$flavor with version $PREFECT_VERSION"
        return 0
    fi
    
    # Setup clean version files for the build (similar to Python script)
    local temp_build_info=""
    local original_build_info="src/prefect/_build_info.py"
    local backup_build_info="${original_build_info}.backup"
    local original_pyproject="pyproject.toml"
    local backup_pyproject="${original_pyproject}.backup"
    local temp_pyproject_dir=""
    local temp_pyproject_file=""
    
    # Create clean version files
    temp_build_info=$(create_temp_version_files "$PREFECT_VERSION")
    temp_pyproject_dir=$(mktemp -d)
    track_temp_dir "$temp_pyproject_dir"
    temp_pyproject_file="$temp_pyproject_dir/pyproject.toml"
    
    # Create modified pyproject.toml with static version
    sed 's/dynamic = \["version"\]/version = "'$PREFECT_VERSION'"/' "$original_pyproject" > "$temp_pyproject_file"
    
    # Backup and replace files
    if [[ -f "$original_build_info" ]]; then
        cp "$original_build_info" "$backup_build_info"
        track_backup "$backup_build_info"
    fi
    cp "$temp_build_info" "$original_build_info"
    
    cp "$original_pyproject" "$backup_pyproject"
    track_backup "$backup_pyproject"
    cp "$temp_pyproject_file" "$original_pyproject"
    
    log "Building with clean version $PREFECT_VERSION..."
    
    # Build tag arguments (using tags generated above)
    local tag_args=()
    for tag in "${tags[@]}"; do
        tag_args+=("--tag" "$tag")
    done
    
    # Build and optionally push
    local build_success=false
    local push_args=()
    if [[ "$NO_PUSH" == "true" ]]; then
        log "Building $image:python$python_version$flavor locally (no push)..."
        push_args+=("--load")  # Load into local Docker instead of pushing
    else
        log "Building and pushing $image:python$python_version$flavor..."
        push_args+=("--push")
    fi
    
    if docker buildx build \
        --file "$dockerfile" \
        --platform "$PLATFORMS" \
        "${build_args[@]}" \
        "${tag_args[@]}" \
        "${push_args[@]}" \
        --pull \
        .; then
        if [[ "$NO_PUSH" == "true" ]]; then
            success "Built $image:python$python_version$flavor locally"
        else
            success "Built and pushed $image:python$python_version$flavor"
        fi
        build_success=true
    else
        warn "Failed to build $image:python$python_version$flavor"
    fi
    
    # Always restore original files
    if [[ -f "$backup_build_info" ]]; then
        mv "$backup_build_info" "$original_build_info"
        untrack_backup "$backup_build_info"
    fi
    
    if [[ -f "$backup_pyproject" ]]; then
        mv "$backup_pyproject" "$original_pyproject"
        untrack_backup "$backup_pyproject"
    fi
    
    # Clean up temp files
    if [[ -n "$temp_build_info" ]]; then
        local temp_dir
        temp_dir=$(dirname "$temp_build_info")
        rm -rf "$temp_dir"
        untrack_temp_dir "$temp_dir"
    fi
    
    if [[ -n "$temp_pyproject_dir" ]]; then
        rm -rf "$temp_pyproject_dir"
        untrack_temp_dir "$temp_pyproject_dir"
    fi
    
    # Return build success status
    [[ "$build_success" == "true" ]]
}

# Build and push all images
build_all_images() {
    # Determine which Python versions to build
    local python_versions_to_build=()
    if [[ -n "$SINGLE_PYTHON_VERSION" ]]; then
        python_versions_to_build=("$SINGLE_PYTHON_VERSION")
        log "Building for single Python version: $SINGLE_PYTHON_VERSION"
    else
        python_versions_to_build=("${PYTHON_VERSIONS[@]}")
        log "Building for all Python versions: ${PYTHON_VERSIONS[*]}"
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        local action="build and push"
        [[ "$NO_PUSH" == "true" ]] && action="build locally"
        log "DRY RUN: Would $action images with version $PREFECT_VERSION"
        log "Python versions: ${python_versions_to_build[*]}"
    else
        local action="Building and pushing"
        [[ "$NO_PUSH" == "true" ]] && action="Building locally"
        log "$action images..."
        log "Python versions: ${python_versions_to_build[*]}"
    fi
    
    local total_builds=0
    local successful_builds=0
    
    for image in "${IMAGES[@]}"; do
        for python_version in "${python_versions_to_build[@]}"; do
            for flavor in "${FLAVORS[@]}"; do
                # Skip incompatible combinations
                if [[ "$image" == "prefect-client" && ("$flavor" == "-conda" || "$flavor" == "-kubernetes") ]]; then
                    continue
                fi
                
                total_builds=$((total_builds + 1))
                
                if build_and_push_image "$image" "$python_version" "$flavor"; then
                    successful_builds=$((successful_builds + 1))
                else
                    error "Failed to build $image:python$python_version$flavor"
                fi
            done
        done
    done
    
    log "Build summary: $successful_builds/$total_builds builds successful"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY RUN: All builds would be attempted"
        return 0
    fi
    
    if [[ $successful_builds -eq $total_builds ]]; then
        if [[ "$NO_PUSH" == "true" ]]; then
            success "All images built locally successfully!"
        else
            success "All images built and pushed successfully!"
        fi
    else
        error "Some builds failed. Check the logs above."
    fi
}

# List pushed images
list_images() {
    log "Listing pushed images..."
    echo ""
    
    for image in "${IMAGES[@]}"; do
        echo "=== $image ==="
        gcloud artifacts docker images list "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${image}" \
            --format="table(IMAGE,TAGS.list():label=TAGS,CREATE_TIME.date():label=CREATED)" \
            --limit=20 2>/dev/null || warn "Could not list images for $image"
        echo ""
    done
}

# Main execution
main() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log "=== DRY RUN MODE - No actual building or pushing will occur ==="
    fi
    
    log "Starting Prefect Docker image release to GCP Artifact Registry"
    log "Project ID: $PROJECT_ID"
    log "Region: $REGION"
    log "Repository: $REPO_NAME"
    log "Platforms: $PLATFORMS"
    log "Dry run: $DRY_RUN"
    log "No push: $NO_PUSH"
    log "Image type: ${IMAGE_TYPE:-<default>}"
    
    PREFECT_VERSION=$(get_version)
    log "Prefect version: $PREFECT_VERSION"
    
    if [[ "$DRY_RUN" != "true" ]]; then
        check_requirements
        setup_buildx
    else
        log "DRY RUN: Skipping requirements check, authentication, repository setup, and buildx setup"
    fi
    
    build_all_images
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "=== DRY RUN SUMMARY ==="
        log "Prefect version: $PREFECT_VERSION"
        if [[ "$NO_PUSH" == "true" ]]; then
            log "Would build locally without pushing"
        else
            log "Would push to: ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/"
        fi
        success "Dry run completed - Docker builds validated!"
        return 0
    fi
    
    if [[ "$NO_PUSH" == "true" ]]; then
        log "=== LOCAL BUILD SUMMARY ==="
        log "Prefect version: $PREFECT_VERSION"
        log "Images built locally and available in Docker daemon"
        success "All Docker images built locally successfully!"
        
        # Show local images
        echo ""
        log "Local Docker images:"
        docker images | grep -E "(prefect|REPOSITORY)" || true
    else
        list_images
        
        success "All Docker images released successfully!"
        log "Repository URL: https://console.cloud.google.com/artifacts/browse/${PROJECT_ID}/${REGION}/${REPO_NAME}"
    fi
    
    # Usage instructions
    echo ""
    log "To pull the images from your registry:"
    echo "docker pull ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/prefect:latest"
    echo "docker pull ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/prefect-client:latest"
    echo ""
    log "To use in Kubernetes deployments, set image:"
    echo "image: ${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/prefect:${PREFECT_VERSION}-python3.12"
}

# Show usage if help is requested
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Usage: $0 [PROJECT_ID] [REGION] [REPO_NAME] [DRY_RUN] [NO_PUSH] [FORCE_RELEASE_VERSION] [SINGLE_PYTHON_VERSION] [IMAGE_TYPE]"
    echo ""
    echo "Build and publish Prefect Docker images to GCP Artifact Registry"
    echo "Uses clean git tag versions instead of dirty development versions"
    echo ""
    echo "Arguments:"
    echo "  PROJECT_ID             GCP project ID (required)"
    echo "  REGION                 GCP region (required, e.g., us-central1, us-west1, europe-west1)"
    echo "  REPO_NAME              Repository name (required)"
    echo "  DRY_RUN                Preview builds without building/pushing (optional, default: 'false', set to 'true' for dry run)"
    echo "  NO_PUSH                Build locally without pushing to registry (optional, default: 'false', set to 'true' to skip push)"
    echo "  FORCE_RELEASE_VERSION  Only allow x.y.z tags (no suffixes) for version (optional, default: 'false', set to 'true' to require strict release version)"
    echo "  SINGLE_PYTHON_VERSION  Build only for specific Python version (optional, e.g., '3.11'). If not specified, builds for all versions."
    echo "  IMAGE_TYPE            Suffix of Dockerfile to use (optional). Example: 'poetry-gcloud' uses 'Dockerfile.poetry-gcloud'.\n                         If empty, uses 'Dockerfile'. Also prefixes the image tag as '<image-type>-<prefect-version>-python<version>'."
    echo ""
    echo "Version handling:"
    echo "  - If FORCE_RELEASE_VERSION=true: Only tags matching x.y.z (e.g., 3.4.11) are allowed."
    echo "  - Otherwise: Allows x.y.z or x.y.z.suffix (e.g., 3.4.11.dev1)"
    echo "  - Passes clean version to Docker build process"
    echo ""
    echo "Configuration:"
    echo "  Python versions: ${PYTHON_VERSIONS[*]}"
    echo "  Flavors: base${FLAVORS[*]}"
    echo "  Images: ${IMAGES[*]}"
    echo "  Platforms: $PLATFORMS"
    echo ""
    echo "Examples:"
    echo "  $0 my-project us-central1 prefect-docker                          # Build all Python versions (default Dockerfile)"
    echo "  $0 my-project us-west1 my-docker-repo                             # Custom region/repo, all versions"
    echo "  $0 my-project us-west1 my-docker-repo true                        # Dry run, all versions"
    echo "  $0 my-project us-west1 my-docker-repo false true                  # Build locally without pushing"
    echo "  $0 my-project us-central1 prefect-docker false false '' 3.11      # Build only Python 3.11 with default Dockerfile"
    echo "  $0 my-project us-central1 prefect-docker false false '' 3.12 poetry-gcloud  # Build using Dockerfile.poetry-gcloud"
    echo ""
    echo "Note: This script builds multi-platform images (amd64/arm64) which requires"
    echo "      Docker buildx and may take significant time and resources."
    exit 0
fi

# Validate required arguments
if [[ -z "$PROJECT_ID" ]]; then
    error "PROJECT_ID is required as the first argument"
fi

if [[ -z "$REGION" ]]; then
    error "REGION is required as the second argument"
fi

if [[ -z "$REPO_NAME" ]]; then
    error "REPO_NAME is required as the third argument"
fi

main "$@"