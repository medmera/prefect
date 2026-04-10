# MMB Release Process

This document describes how to prepare and publish new MMB releases of Prefect
and its integration packages (e.g. `prefect-gcp`) to the internal GCP Artifact
Registry.

MMB maintains a fork of [PrefectHQ/prefect](https://github.com/PrefectHQ/prefect)
with a small number of custom changes (IAP authentication, GCP Artifact Registry
publishing, custom Dockerfiles, etc.). This process keeps those changes intact
while tracking upstream Prefect releases.

---

## Branch structure

| Branch | Purpose |
|--------|---------|
| `main` | Mirrors upstream `PrefectHQ/prefect` main — do not commit MMB changes here |
| `release` | Long-lived branch: all MMB changes live here, accumulated over time |
| `release-prep/<tag>` | Temporary branches created per release cycle; deleted after merging |

---

## Workflow overview

```
1. mmb-sync-main          Sync fork main and all tags from upstream
        ↓
2. mmb-prepare-release    Create release-prep/<tag>, merge upstream tag, open PR
        ↓
3. Review & merge PR      Resolve any conflicts, then merge into release
        ↓
4. mmb-release-packages   Build and publish Python packages + Docker images
```

All four steps are GitHub Actions workflows that can be dispatched from the
**Actions** tab in GitHub.

---

## Step-by-step

### 1. Sync main (`mmb-sync-main`)

Dispatch **MMB - Sync Main & Tags** from the Actions tab.

- Fast-forwards `main` to match upstream `PrefectHQ/prefect` main
- Pushes all upstream tags to this fork (e.g. `3.4.25`, `prefect-gcp-0.6.17`)

Run this before preparing a release so that the new tags are available.

> Use the **dry run** option first to preview what will be synced.

---

### 2. Prepare release (`mmb-prepare-release`)

Dispatch **MMB - Prepare Release** from the Actions tab with:

| Input | Example | Description |
|-------|---------|-------------|
| `base_tag` | `3.4.25` | The upstream Prefect tag to adopt |
| `dry_run` | `false` | Set `true` to preview without making changes |

What the workflow does:

1. Creates a new branch `release-prep/3.4.25` from the current `release` HEAD
2. Runs `git merge 3.4.25` — merging the upstream tag into our branch
3. Pushes `release-prep/3.4.25` and opens a PR → `release`

**Clean merge:** the PR is ready to review and merge immediately.

**Conflicts:** the workflow commits the conflict markers so the branch can be
pushed, marks the PR with the `needs-conflict-resolution` label, and includes
resolution instructions in the PR body.

> Use **dry run** first to see which upstream commits would be merged and whether
> conflicts are likely.

---

### 3. Review and merge the PR

Open the PR created by step 2.

**No conflicts:** review the diff (upstream changes merged cleanly with MMB
changes) and merge.

**With conflicts:** the commit on the branch contains raw conflict markers
(`<<<<<<<`, `=======`, `>>>>>>>`). Resolve them:

```bash
git fetch origin
git checkout release-prep/3.4.25

# Edit each conflicted file to resolve markers, then:
git add <resolved-files>
git commit -m "resolve conflicts merging 3.4.25"
git push origin release-prep/3.4.25
```

Once the PR is green and conflicts are resolved, merge it. The `release` branch
now contains the upstream changes plus all MMB customisations.

The `release-prep/<tag>` branch can be deleted after the PR is merged.

---

### 4. Release packages (`mmb-release-packages`)

Dispatch **MMB - Release Packages** from the Actions tab.

| Input | Description |
|-------|-------------|
| `release_python` | Build and publish Python wheels/sdists |
| `release_docker` | Build and push Docker images |
| `build_integrations` | Include integration packages (e.g. `prefect-gcp`) |
| `dry_run` | Preview without actually publishing |
| `force_release_version` | Require a strict `x.y.z` tag (no pre-release suffixes) |

The workflow builds from the `release` branch HEAD and determines versions
using `git describe` to find the nearest ancestor tag — so the version number
always matches the actual code in the working tree.

---

## Version numbering

Package versions are derived from upstream git tags that are ancestors of the
current `release` branch HEAD:

- **prefect core:** the nearest `x.y.z` ancestor tag (e.g. `3.4.25`)
- **prefect-gcp:** the nearest `prefect-gcp-x.y.z` ancestor tag (e.g. `0.6.17`)
- **other integrations:** same pattern

After merging a new upstream tag via the prepare-release PR, `git describe`
automatically picks up the new version. No manual tagging is required.

---

## Adding MMB-specific changes

When adding new custom changes to `release`:

1. Commit directly to `release` (or open a PR to `release`)
2. Prefix the commit message with `[MMB]` to make custom commits easy to
   identify in `git log`:

   ```
   [MMB] Add IAP auth header to prefect server requests
   [MMB] Update Dockerfile to pin git version and add mime-support
   ```

These commits stay on `release` permanently and are preserved across all future
upstream merges.

---

## Troubleshooting

**"Tag not found after fetch"**
Run `mmb-sync-main` first to pull the latest upstream tags into this fork.

**"Branch release-prep/X.Y.Z already exists"**
A previous prepare-release run left a branch behind. Delete it:
```bash
git push origin --delete release-prep/X.Y.Z
```
Then re-run the workflow.

**"Tag is already an ancestor of release"**
The `release` branch already contains this tag (it was merged in a previous
cycle). Either the release is already prepared, or you need a newer tag.

**Build produces wrong version for an integration package**
Verify that the integration tag (e.g. `prefect-gcp-0.6.17`) is an ancestor of
the current `release` HEAD:
```bash
git merge-base --is-ancestor prefect-gcp-0.6.17 release && echo "ancestor" || echo "not ancestor"
```
If it is not an ancestor, the prepare-release PR for the corresponding upstream
tag has not been merged yet.
