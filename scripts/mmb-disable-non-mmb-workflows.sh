#!/usr/bin/env bash
# Disable every GitHub Actions workflow in the current repository whose display name does
# not start with "MMB". MMB workflows (name: "MMB - ...") stay enabled.
#
# Use after syncing from upstream so fork PRs do not run upstream workflows.
#
# Requirements: gh CLI authenticated (gh auth login), jq.
#
# Usage:
#   ./scripts/mmb-disable-non-mmb-workflows.sh          # disable matching workflows
#   ./scripts/mmb-disable-non-mmb-workflows.sh --dry-run
#   REPO=owner/name ./scripts/mmb-disable-non-mmb-workflows.sh

set -euo pipefail
set -o pipefail

dry_run=false
if [[ "${1:-}" == "--dry-run" ]]; then
  dry_run=true
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI is not installed" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is not installed" >&2
  exit 1
fi

repo="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)}"
if [[ -z "$repo" ]]; then
  echo "error: could not determine repository; set REPO=owner/name or run inside a gh repo" >&2
  exit 1
fi

echo "Repository: $repo"
echo ""

count=0
while IFS=$'\t' read -r id name state || [[ -n "${id:-}" ]]; do
  [[ -z "${id:-}" ]] && continue
  count=$((count + 1))
  if [[ "$state" == "disabled_manually" ]]; then
    echo "skip (already disabled): $name [$id]"
    continue
  fi
  if $dry_run; then
    echo "would disable: $name [$id] (state=$state)"
  else
    echo "disabling: $name [$id]"
    gh workflow disable "$id" --repo "$repo"
  fi
done < <(
  gh workflow list --repo "$repo" --json name,id,state --limit 500 \
    | jq -r '.[] | select(.name | startswith("MMB") | not) | "\(.id)\t\(.name)\t\(.state)"'
)

if [[ "$count" -eq 0 ]]; then
  echo "No non-MMB workflows found (or none returned by the API)."
fi

if $dry_run && [[ "$count" -gt 0 ]]; then
  echo ""
  echo "Dry run only; no changes made. Re-run without --dry-run to disable."
fi
