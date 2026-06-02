# MMB Release Process

> **Full guide:** see [`MMB_DOCUMENTATION.md`](../MMB_DOCUMENTATION.md) for local setup (`just`, `gh`), CI vs local responsibilities, and troubleshooting.

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
1. mmb-sync-main (GitHub Actions)   Sync fork main and all tags from upstream
        ↓
2. mmb-prepare-release (local)      Create release-prep/<tag>, merge upstream tag, open PR
        ↓
3. Review & merge PR                CI runs on PR; merge into release when green
        ↓
4. mmb-release-packages (GitHub Actions)   Build and publish Python packages + Docker images
```

Steps 1, 3 (CI), and 4 run in GitHub Actions. Step 2 runs locally with your
git and `gh` credentials so you can resolve merge conflicts interactively before
pushing.

---

## Step-by-step

### 1. Sync main (`mmb-sync-main`)

Dispatch **MMB - Sync Main & Tags** from the Actions tab.

- Fast-forwards `main` to match upstream `PrefectHQ/prefect` main
- Pushes all upstream tags to this fork (e.g. `3.4.25`, `prefect-gcp-0.6.17`)

Run this before preparing a release so that the new tags are available.

> Use the **dry run** option first to preview what will be synced.

---

### 2. Prepare release (local)

Run from a clean working tree in your local clone:

```bash
# Preview first
./scripts/mmb-prepare-release.sh --dry-run 3.4.25

# Create branch, merge, resolve conflicts, push, and open PR
./scripts/mmb-prepare-release.sh 3.4.25

# Or via just
just mmb-prepare-release 3.4.25
```

**Prerequisites:**

- Clean working tree (commit or stash first)
- `gh` CLI installed and authenticated (`gh auth login`)
- Upstream tags synced via step 1

| Flag | Description |
|------|-------------|
| `--dry-run` | Preview commits and branch plan without making changes |
| `--no-pr` | Push the branch but skip `gh pr create` |
| `--no-open` | Create the PR but do not open it in a browser |

What the script does:

1. Fetches `upstream` and `origin` tags
2. Creates `release-prep/3.4.25` from the current `origin/release` HEAD
3. Runs `git merge 3.4.25`
4. If conflicts occur, pauses for interactive resolution (editor, `git mergetool`)
5. Pushes the branch and opens a PR → `release` via `gh`

**Clean merge:** the PR is ready to review and merge immediately.

**Conflicts:** resolve them locally before the branch is pushed. The script
validates that no conflict markers or unmerged paths remain, then commits and
pushes a clean merge commit.

> Use `--dry-run` first to see which upstream commits would be merged.

For headless automation (no interactive conflict resolution), use
`./scripts/prepare-release-branch.sh` instead. It exits on conflicts unless
`--commit-conflicts` is passed.

---

### 3. Review and merge the PR

Open the PR created by step 2 (or the URL printed by the script).

**No conflicts:** review the diff (upstream changes merged cleanly with MMB
changes) and merge once **MMB - Unit tests** CI is green.

**With conflicts:** these should already be resolved before push. If you need
to make further changes after the PR is opened:

```bash
git fetch origin
git checkout release-prep/3.4.25

# Make edits, then:
git add <files>
git commit -m "address review feedback for 3.4.25 merge"
git push origin release-prep/3.4.25
```

Once the PR is green, merge it with a **merge commit** — never squash or rebase.
Squash merges drop upstream tag ancestry, so `git describe` resolves wrong package
versions during release (e.g. `prefect-gcp==0.6.18.post1` instead of `0.6.19`).

```bash
gh pr merge --merge   # correct
# Do NOT use: gh pr merge --squash or --rebase
```

The `release-prep/<tag>` branch is merged locally with `git merge <tag>`, which
creates a two-parent merge commit. GitHub must preserve that structure when
landing the PR on `release`.

The `release` branch now contains the upstream changes plus all MMB customisations.

The `release-prep/<tag>` branch can be deleted after the PR is merged.

---

### 4. Release packages (`mmb-release-packages`)

Dispatch **MMB - Release Packages** from the Actions tab.

| Input | Description |
|-------|-------------|
| `release_python` | Build and publish Python wheels/sdists |
| `release_docker` | Build and push Docker images |
| `build_integrations` | Include allowlisted integration packages (see `scripts/mmb-publish-integrations.conf`) |
| `dry_run` | Preview without actually publishing |
| `force_release_version` | Require a strict `x.y.z` base (no pre-release suffixes on base) |
| `version_post` | Post number for prefect (empty = none; `1` → `.post1`) |
| `integration_version_post` | Post number for integrations (empty = none) |
| `base_version_override` | Force core base `x.y.z` (empty = auto from git) |

The workflow builds from the `release` branch HEAD. Base versions use the nearest
upstream-style ancestor tag (`git describe`); `-mmb` suffixes on tags are
ignored for version numbers. Python and Docker share `scripts/release-version-lib.sh`.

Integration packages are published only when listed in
[`scripts/mmb-publish-integrations.conf`](../scripts/mmb-publish-integrations.conf)
(currently `prefect-gcp`, `prefect-dbt`, and `prefect-shell`). Core `prefect` is always published
when `release_python=true`.

### Post-release (MMB-only patch)

If `x.y.z` is already in Artifact Registry and you fixed `release` without a new
upstream tag:

1. Merge the fix to `release`.
2. Dispatch with `version_post=1`, `build_integrations=false` (unless integrations changed).
3. `dry_run=true` — confirm `x.y.z.post1` in logs.
4. `dry_run=false` — publish Python and Docker.
5. Install with `prefect==x.y.z.post1`.

---

## Version numbering

Package versions are derived from upstream git tags that are ancestors of the
current `release` branch HEAD:

- **prefect core:** the nearest `x.y.z` ancestor tag (e.g. `3.4.25`)
- **prefect-gcp:** the nearest `prefect-gcp-x.y.z` ancestor tag (e.g. `0.6.17`)
- **other integrations:** same pattern

After merging a new upstream tag via the prepare-release PR, `git describe`
automatically picks up the new version. No manual tagging is required.

### MMB release tags

After a successful publish, the **MMB - Release Packages** workflow creates
annotated git tags on the released commit to mark exactly what was published
internally:

| Published package | Tag created |
|-------------------|-------------|
| `prefect` core | `3.4.25-mmb` or `3.7.2.post1-mmb` |
| `prefect-gcp` | `prefect-gcp-0.6.17-mmb` |
| `prefect-dbt` | `prefect-dbt-0.7.20-mmb` |
| (allowlisted integrations only) | `{package}-{version}-mmb` |

Tags are created and pushed by `scripts/create-mmb-release-tags.sh` using the
`PREFECT_REPO_PAT` secret. A few important behaviors:

- **Per-package tagging:** only packages that were successfully uploaded receive
  a tag. If a single integration fails to upload while others succeed, only the
  successful ones are tagged.
- **Dry runs never create tags.** When the workflow is dispatched with
  `dry_run=true`, the tag step is skipped entirely.
- **Idempotent re-runs:** if a tag already points at the same commit (e.g. when
  retrying a partially failed run), the script skips it silently. If a tag
  already exists at a *different* commit, the step fails with an error rather
  than silently moving the tag.

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
The local script resets an existing prep branch automatically. To start fresh,
delete the remote branch first:
```bash
git push origin --delete release-prep/X.Y.Z
```
Then re-run `./scripts/mmb-prepare-release.sh X.Y.Z`.

**"Tag is already an ancestor of release"**
The `release` branch already contains this tag (it was merged in a previous
cycle). Either the release is already prepared, or you need a newer tag.

**"gh is not authenticated"**
Run `gh auth login` and ensure you have permission to push branches and create
PRs on the fork.

**"Tag X.Y.Z-mmb already exists at a DIFFERENT commit"**
A previous release run already tagged a different commit. If you intentionally
want to re-tag (e.g. after amending the release branch), delete the old tag
first:
```bash
git push origin --delete 3.4.25-mmb
```
Then re-run the workflow. The script will never silently move an existing tag.

**Build produces wrong version for an integration package**
Verify that the integration tag (e.g. `prefect-gcp-0.6.17`) is an ancestor of
the current `release` HEAD:
```bash
git merge-base --is-ancestor prefect-gcp-0.6.17 release && echo "ancestor" || echo "not ancestor"
```
If it is not an ancestor, the prepare-release PR for the corresponding upstream
tag has not been merged yet.

**Python upload fails: version already exists**
Use `version_post=1` (or the next post number) to publish a new immutable version.
`pip install prefect==x.y.z` will not install a post release.

**Version resolution fails after `-mmb` tags exist**
MMB tags are stripped during resolution. Use `base_version_override` if needed.
