# MMB Custom Scripts

This document describes custom scripts created for managing the Medmera fork of Prefect.

## Upstream Sync Script

### Overview

The `scripts/sync-release-branch.sh` script automates the process of syncing changes from the upstream Prefect repository into our forked release branch while preserving any custom changes we've made.

### Purpose

This script solves the common problem in forked repositories where you need to:

1. Keep your main branch in sync with upstream
2. Bring upstream changes into your release branch
3. Preserve your custom commits by rebasing them on top of upstream changes

### What the Script Does

The script performs these operations automatically:

1. **Pre-flight Checks** - Validates repository state and prerequisites
2. **Backup Creation** - Creates a timestamped backup branch for safety
3. **Upstream Sync** - Fetches and fast-forwards main branch with upstream changes
4. **Release Branch Update** - Rebases custom commits onto the updated main branch
5. **Push Updates** - Pushes the synchronized branches to origin

### Visual Example

Here's what happens to your branches when running the script:

#### Scenario:

- Upstream has 2 new commits not in your origin/main
- Your origin/release has 1 custom commit

#### Before Script:

```
upstream/main:    A---B---U1---U2  (2 new commits)
                       |
origin/main:      A---B            (behind by 2 commits)
                       |
origin/release:   A---B---C1       (1 custom commit)
```

#### After Script:

```
upstream/main:    A---B---U1---U2
                           |
origin/main:      A---B---U1---U2  (fast-forwarded)
                           |
origin/release:   A---B---U1---U2---C1'  (rebased)
```

#### What Happened:

- **Main branch**: Fast-forwarded to include upstream commits U1, U2
- **Release branch**: Custom commit C1 rebased as C1' on top of updated main
- **Result**: Release branch has all upstream changes + custom changes on top

### Prerequisites

- Clean working tree (no uncommitted changes)
- Upstream remote configured pointing to `PrefectHQ/prefect`
- Origin remote configured pointing to your fork
- Both `main` and `release` branches exist locally

### Usage

```bash
# Test what the script will do (recommended first run)
./scripts/sync-release-branch.sh --dry-run

# Actually perform the sync
./scripts/sync-release-branch.sh

# Show help and options
./scripts/sync-release-branch.sh --help
```

### Safety Features

- **Automatic Backup**: Creates timestamped backup branch before any changes
- **Pre-flight Checks**: Validates repository state and configuration
- **Dry Run Mode**: Preview what will happen without making changes
- **Force-with-lease**: Safe force pushing that prevents accidental overwrites
- **Conflict Detection**: Clear guidance when manual conflict resolution is needed
- **Clean Exit**: Returns to original branch when done

### Step-by-Step Process

1. **Validation Phase**

   - Checks you're in a git repository
   - Verifies upstream and origin remotes exist
   - Confirms main and release branches exist
   - Ensures working tree is clean

2. **Backup Phase**

   - Creates backup branch: `backup-before-sync-YYYYMMDD-HHMMSS`
   - Records current branch for restoration

3. **Main Branch Sync**

   - Fetches from upstream remote
   - Switches to main branch
   - Fast-forwards main with upstream/main
   - Pushes updated main to origin

4. **Release Branch Update**

   - Switches to release branch
   - Counts commits ahead of main
   - If no custom commits: fast-forwards to match main
   - If custom commits exist: rebases them onto updated main
   - Force-pushes rebased release branch to origin

5. **Cleanup**
   - Returns to original branch
   - Reports success summary

### Error Handling

The script handles common scenarios:

- **Dirty Working Tree**: Exits with clear message to commit or stash changes
- **Missing Remotes**: Provides instructions for remote configuration
- **Non-fast-forward Main**: Suggests using `git reset --hard upstream/main`
- **Rebase Conflicts**: Provides commands for manual conflict resolution
- **Missing Branches**: Exits with clear error about branch requirements

### Configuration

The script uses these default values (editable at the top of the script):

```bash
UPSTREAM_REMOTE="upstream"
ORIGIN_REMOTE="origin"
MAIN_BRANCH="main"
RELEASE_BRANCH="release"
```

### Recovery

If something goes wrong, you can restore from the backup:

```bash
# List backup branches
git branch | grep backup-before-sync

# Restore from a specific backup
git checkout backup-before-sync-20231201-143022
```

### When to Use

Run this script when:

- Upstream has new commits you want to incorporate
- You need to update your release branch with latest upstream changes
- You want to ensure your custom changes stay on top of upstream updates
- You're preparing for a release that should include latest upstream features

### Repository Setup

If you need to set up the upstream remote:

```bash
git remote add upstream git@github.com:PrefectHQ/prefect.git
git fetch upstream
```

---

## GitHub Workflow Integration

### Automated Sync Workflow

The sync process has been automated with a GitHub workflow located at `.github/workflows/sync-upstream.yaml`.

#### Triggering the Workflow

The workflow can be triggered manually from the GitHub UI:

1. Go to the **Actions** tab in your GitHub repository
2. Select **"Sync Upstream Changes"** from the workflow list
3. Click **"Run workflow"**
4. Choose your options:
   - **Dry run**: Preview what will happen without making changes
   - **Force sync**: Proceed even if conflicts are detected (use with caution)
5. Click **"Run workflow"** to start

#### Workflow Features

- **Manual Trigger**: Uses `workflow_dispatch` for on-demand execution
- **Dry Run Mode**: Preview changes before executing
- **Automatic Authentication**: Handles Git authentication via GitHub token
- **Comprehensive Reporting**: Provides detailed summary of sync results
- **Error Handling**: Clear guidance when manual intervention is needed
- **Safety Controls**: Prevents concurrent sync operations

#### Workflow Inputs

| Input        | Description                               | Default | Required |
| ------------ | ----------------------------------------- | ------- | -------- |
| `dry_run`    | Perform a dry run without making changes  | `false` | No       |
| `force_sync` | Force sync even if conflicts are detected | `false` | No       |

#### What the Workflow Does

1. **Setup Phase**

   - Checks out the repository with full history
   - Configures Git with bot credentials
   - Adds upstream remote if not present
   - Makes the sync script executable

2. **Sync Phase** (if not dry run)

   - Runs the `sync-release-branch.sh` script
   - Handles authentication for pushing changes
   - Captures any errors for reporting

3. **Reporting Phase**
   - Creates detailed summary of changes
   - Shows branch status and commit counts
   - Lists custom commits that were rebased
   - Provides error guidance if sync fails

#### Workflow Outputs

The workflow creates a detailed job summary showing:

- ✅ Branch update status
- 📈 Commit counts on each branch
- 🔧 Number of custom commits rebased
- 📝 Recent commit history
- 🎯 List of custom commits (if any)

#### Error Handling

If the sync fails, the workflow provides:

- Clear error messages
- Manual resolution steps
- Commands to run locally
- Backup branch information

#### Security Considerations

- Uses `GITHUB_TOKEN` for authentication (no additional secrets needed)
- Limited permissions: `contents: write`, `actions: read`
- Prevents concurrent operations with concurrency controls
- Safe force-pushing with `--force-with-lease`

### Local vs Workflow Execution

| Aspect                  | Local Execution       | GitHub Workflow           |
| ----------------------- | --------------------- | ------------------------- |
| **Trigger**             | Manual command        | GitHub UI button          |
| **Environment**         | Your machine          | GitHub Actions runner     |
| **Authentication**      | Your Git credentials  | GitHub token              |
| **Feedback**            | Terminal output       | GitHub UI summary         |
| **Backup**              | Local backup branches | Same backup branches      |
| **Conflict Resolution** | Interactive           | Requires manual local fix |

### When to Use Each Method

**Use Local Execution When:**

- You want immediate feedback and control
- You expect merge conflicts that need resolution
- You're testing or developing the script
- You need to inspect changes before pushing

**Use GitHub Workflow When:**

- You want a clean, audited process
- Multiple team members need to trigger syncs
- You want automated reporting and summaries
- You're performing routine, conflict-free syncs

---

## Release Scripts

### Overview

The Medmera fork includes two custom release scripts for deploying Prefect packages and Docker images to Google Cloud Platform (GCP) Artifact Registry instead of the default PyPI and DockerHub repositories used in CI/CD.

### Scripts

#### 1. `release-python-packages.sh` - Python Package Deployment

**Location:** `scripts/release-python-packages.sh`

Builds and publishes the `prefect` package, `prefect-client` package, and all integration packages (prefect-aws, prefect-gcp, etc.) to GCP Artifact Registry.

**Features:**

- Builds the full `prefect` package, the lightweight `prefect-client` package, and all integration packages
- Uses the same build process as the CI/CD pipeline (uv for core packages, python -m build for integrations)
- Automatically creates the GCP Artifact Registry repository if it doesn't exist
- Handles authentication and configuration
- Provides detailed logging and error handling
- Optional integration package building (can be disabled)
- Uses clean git tag versions instead of dirty development versions

**Usage:**

```bash
# Using environment variables (recommended)
export PREFECT_GCP_PROJECT_ID="your-project-id"
export PREFECT_GCP_REGION="us-central1"
export PREFECT_PYPI_REPO_NAME="prefect-pypi"
./scripts/release-python-packages.sh

# Using command line arguments
./scripts/release-python-packages.sh my-project us-west1 my-pypi-repo

# Skip integration packages (faster build)
./scripts/release-python-packages.sh my-project us-west1 my-pypi-repo false

# Dry run to see what would be built
./scripts/release-python-packages.sh my-project us-west1 my-pypi-repo true true

# Show help
./scripts/release-python-packages.sh --help
```

#### 2. `release-docker-images.sh` - Docker Image Deployment

**Location:** `scripts/release-docker-images.sh`

Builds and publishes Prefect Docker images to GCP Artifact Registry with multiple Python versions and flavors.

**Features:**

- Builds images for Python versions: 3.9, 3.10, 3.11, 3.12, 3.13
- Supports multiple flavors: base, conda, kubernetes
- Creates `prefect` images (prefect-client builds commented out in current version)
- Multi-platform builds (linux/amd64, linux/arm64)
- Follows the same tagging strategy as the official releases
- Uses Docker buildx for efficient multi-platform builds
- Uses clean git tag versions instead of dirty development versions
- Supports building specific Python versions or all versions

**Usage:**

```bash
# Using environment variables (recommended)
export PREFECT_GCP_PROJECT_ID="your-project-id"
export PREFECT_GCP_REGION="us-central1"
export PREFECT_DOCKER_REPO_NAME="prefect-docker"
./scripts/release-docker-images.sh

# Using command line arguments
./scripts/release-docker-images.sh my-project us-west1 my-docker-repo

# Dry run to see what would be built
./scripts/release-docker-images.sh my-project us-west1 my-docker-repo true

# Build locally without pushing
./scripts/release-docker-images.sh my-project us-west1 my-docker-repo false true

# Build only Python 3.11 images
./scripts/release-docker-images.sh my-project us-central1 prefect-docker false false 3.11

# Dry run for Python 3.12 only
./scripts/release-docker-images.sh my-project us-central1 prefect-docker true false 3.12

# Show help
./scripts/release-docker-images.sh --help
```

### Prerequisites

#### Required Tools

1. **Google Cloud CLI (`gcloud`)**

   ```bash
   # Install gcloud CLI
   curl https://sdk.cloud.google.com | bash
   exec -l $SHELL
   ```

2. **UV Package Manager**

   ```bash
   # Install UV
   curl -LsSf https://astral.sh/uv/install.sh | sh
   ```

3. **Docker with Buildx** (for Docker script)

   ```bash
   # Install Docker Desktop or Docker Engine
   # Buildx is included in Docker Desktop and recent Docker Engine versions
   docker buildx version
   ```

4. **Twine** (installed automatically by the Python script)

#### Available Integration Packages

The script automatically discovers and builds all integration packages in `src/integrations/`:

- `prefect-aws` - Amazon Web Services integrations
- `prefect-azure` - Microsoft Azure integrations
- `prefect-gcp` - Google Cloud Platform integrations
- `prefect-kubernetes` - Kubernetes integrations
- `prefect-docker` - Docker integrations
- `prefect-dbt` - dbt integrations
- `prefect-github` - GitHub integrations
- `prefect-gitlab` - GitLab integrations
- `prefect-slack` - Slack integrations
- `prefect-email` - Email integrations
- `prefect-redis` - Redis integrations
- `prefect-sqlalchemy` - SQLAlchemy integrations
- `prefect-snowflake` - Snowflake integrations
- `prefect-databricks` - Databricks integrations
- `prefect-dask` - Dask integrations
- `prefect-ray` - Ray integrations
- `prefect-shell` - Shell integrations
- `prefect-bitbucket` - Bitbucket integrations

### GCP Setup

1. **Create GCP Project** (if not existing)

   ```bash
   gcloud projects create your-project-id
   gcloud config set project your-project-id
   ```

2. **Enable Artifact Registry API**

   ```bash
   gcloud services enable artifactregistry.googleapis.com
   ```

3. **Set up authentication**

   ```bash
   gcloud auth login
   gcloud auth application-default login
   ```

4. **Create service account** (optional, for CI/CD)

   ```bash
   gcloud iam service-accounts create prefect-release \
       --description="Service account for Prefect releases" \
       --display-name="Prefect Release"

   gcloud projects add-iam-policy-binding your-project-id \
       --member="serviceAccount:prefect-release@your-project-id.iam.gserviceaccount.com" \
       --role="roles/artifactregistry.writer"
   ```

### Configuration

#### GitHub Repository Variables

For the automated workflow, configure these GitHub repository variables:

| Variable Name                   | Description            | Example Value        |
| ------------------------------- | ---------------------- | -------------------- |
| `ARTIFACT_REGISTRY_GCP_PROJECT` | GCP project ID         | `my-company-prefect` |
| `ARTIFACT_REGISTRY_GCP_REGION`  | GCP region             | `us-central1`        |
| `ARTIFACT_REGISTRY_PYTHON_NAME` | Python repository name | `prefect-pypi`       |
| `ARTIFACT_REGISTRY_DOCKER_NAME` | Docker repository name | `prefect-docker`     |

To configure these variables:

1. Go to your GitHub repository
2. Navigate to **Settings** → **Secrets and variables** → **Actions**
3. Click the **Variables** tab
4. Add each variable with your desired values

#### Command Line Arguments

Both scripts accept up to 5 positional arguments:

**Python packages script:**

1. **PROJECT_ID** - GCP project ID
2. **REGION** - GCP region (e.g., us-central1, us-west1, europe-west1)
3. **REPO_NAME** - Artifact Registry repository name
4. **BUILD_INTEGRATIONS** - Build integration packages (true/false, default: true)
5. **DRY_RUN** - Preview without building (true/false, default: false)

**Docker images script:**

1. **PROJECT_ID** - GCP project ID
2. **REGION** - GCP region
3. **REPO_NAME** - Artifact Registry repository name
4. **DRY_RUN** - Preview without building (true/false, default: false)
5. **NO_PUSH** - Build locally without pushing (true/false, default: false)
6. **SINGLE_PYTHON_VERSION** - Build only for specific Python version (optional, e.g., '3.11'). If not specified, builds for all versions (3.9-3.13)

### Usage Examples

#### Complete Release Process

```bash
# Set up environment
export PREFECT_GCP_PROJECT_ID="my-prefect-project"
export PREFECT_GCP_REGION="us-central1"

# Release Python packages
./scripts/release-python-packages.sh

# Release Docker images (this will take a while due to multi-platform builds)
./scripts/release-docker-images.sh
```

#### Installing from Your Registry

After successful deployment, you can install packages from your registry:

```bash
# Install Python packages
pip install --index-url https://us-central1-python.pkg.dev/my-project/prefect-pypi/simple/ prefect
pip install --index-url https://us-central1-python.pkg.dev/my-project/prefect-pypi/simple/ prefect-client

# Install integration packages
pip install --index-url https://us-central1-python.pkg.dev/my-project/prefect-pypi/simple/ prefect-aws
pip install --index-url https://us-central1-python.pkg.dev/my-project/prefect-pypi/simple/ prefect-gcp
pip install --index-url https://us-central1-python.pkg.dev/my-project/prefect-pypi/simple/ prefect-kubernetes
# ... and other integration packages

# Pull Docker images
docker pull us-central1-docker.pkg.dev/my-project/prefect-docker/prefect:latest
docker pull us-central1-docker.pkg.dev/my-project/prefect-docker/prefect-client:latest
```

#### Using in Kubernetes

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prefect-server
spec:
  template:
    spec:
      containers:
        - name: prefect-server
          image: us-central1-docker.pkg.dev/my-project/prefect-docker/prefect:3.4.11-python3.12
          # ... rest of configuration
```

### Automated Release Workflow

The release process has been automated with a GitHub workflow located at `.github/workflows/release-packages.yaml`.

#### Triggering the Release Workflow

The workflow can be triggered manually from the GitHub UI:

1. Go to the **Actions** tab in your GitHub repository
2. Select **"Release Packages"** from the workflow list
3. Click **"Run workflow"**
4. Choose your options:
   - **Release Python packages**: Build and push Python packages
   - **Release Docker images**: Build and push Docker images
   - **Build integrations**: Include integration packages in Python build
   - **Dry run**: Preview what would be built without actually building

**Note:** GCP project, region, and repository names are configured via GitHub repository variables (see Configuration section below). 5. Click **"Run workflow"** to start

#### Workflow Features

- **Matrix Strategy**: Builds all Python versions (3.9-3.13) in parallel for maximum efficiency
- **Parallel Jobs**: Python packages and Docker images build simultaneously
- **Dry Run Mode**: Preview what would be built without making changes
- **Selective Building**: Choose to build just Python packages, just Docker images, or both
- **Integration Control**: Option to include or exclude integration packages
- **Automatic Setup**: Handles GCP authentication and repository creation
- **Comprehensive Logging**: Detailed output for troubleshooting per Python version

### Troubleshooting

#### Common Issues

1. **Authentication Errors**

   ```bash
   # Re-authenticate
   gcloud auth login
   gcloud auth configure-docker us-central1-docker.pkg.dev
   ```

2. **Permission Errors**

   ```bash
   # Check your IAM permissions
   gcloud projects get-iam-policy your-project-id

   # You need these roles:
   # - roles/artifactregistry.admin (to create repositories)
   # - roles/artifactregistry.writer (to push artifacts)
   ```

3. **Docker Buildx Issues**

   ```bash
   # Reset buildx
   docker buildx rm prefect-builder
   docker buildx create --name prefect-builder --use
   ```

4. **Disk Space Issues**

   ```bash
   # Clean up Docker to free space
   docker system prune -a
   ```

5. **Path Issues**
   ```bash
   # Make sure you run scripts from repository root
   cd /path/to/prefect-repository
   ./scripts/release-python-packages.sh
   ```

#### Getting Help

- Run either script with `--help` or `-h` for detailed usage information
- Check the script logs for detailed error messages
- Verify GCP authentication: `gcloud auth list`
- Check GCP project: `gcloud config get-value project`

#### Version Handling

Both scripts use clean git tag versions:

- **Prefect core**: Uses latest tag matching `x.x.x` pattern (e.g., `3.4.11`)
- **Integrations**: Uses latest tag matching `prefect-{name}-x.x.x` pattern (e.g., `prefect-aws-0.5.9`)
- **Fallback**: Uses dynamic version if no clean tag found

### Security Considerations

- The scripts use OAuth2 tokens for authentication, which are temporary and secure
- For CI/CD environments, consider using service account keys
- Repository access can be controlled through GCP IAM policies
- Consider using VPC-native repositories for additional network security
- GitHub workflow uses `GITHUB_TOKEN` and requires GCP service account key for authentication

### Cost Considerations

- GCP Artifact Registry charges for storage and data transfer
- Multi-platform Docker builds require more resources and time
- Consider cleanup policies to manage storage costs:
  ```bash
  # Set up cleanup policy (example: keep only 10 latest versions)
  gcloud artifacts repositories describe prefect-docker --location=us-central1
  ```

---

## Future Scripts

Additional custom scripts for managing the Medmera fork can be documented here as they are created.
