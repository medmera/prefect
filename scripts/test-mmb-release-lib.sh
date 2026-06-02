#!/bin/bash
# Unit-style tests for mmb-release-lib.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/mmb-release-lib.sh
source "${SCRIPT_DIR}/mmb-release-lib.sh"

failures=0
TMP_DIR=""

cleanup() {
    [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
}
trap cleanup EXIT

assert_eq() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$expected" != "$actual" ]]; then
        echo "FAIL: ${name}: expected '${expected}', got '${actual}'" >&2
        failures=$((failures + 1))
    else
        echo "OK: ${name}"
    fi
}

assert_fail() {
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        echo "FAIL: ${name}: expected failure" >&2
        failures=$((failures + 1))
    else
        echo "OK: ${name}"
    fi
}

TMP_DIR="$(mktemp -d)"
cd "$REPO_ROOT"

# --- load_mmb_publish_allowlist from file ---
MMB_PUBLISH_INTEGRATIONS=""
MMB_PUBLISH_INTEGRATIONS_CONF="${TMP_DIR}/allowlist.conf"
cat > "$MMB_PUBLISH_INTEGRATIONS_CONF" <<'EOF'
# comment
prefect-gcp

prefect-dbt
prefect-aws
EOF

load_mmb_publish_allowlist
assert_eq "load file count" "3" "${#MMB_PUBLISH_ALLOWLIST[@]}"
assert_eq "load file order" "prefect-gcp prefect-dbt prefect-aws" "${MMB_PUBLISH_ALLOWLIST[*]}"

# --- env override ---
MMB_PUBLISH_INTEGRATIONS="prefect-gcp,prefect-dbt"
load_mmb_publish_allowlist
assert_eq "env override count" "2" "${#MMB_PUBLISH_ALLOWLIST[@]}"
assert_eq "env override values" "prefect-gcp prefect-dbt" "${MMB_PUBLISH_ALLOWLIST[*]}"

# --- validate existing packages ---
MMB_PUBLISH_INTEGRATIONS="prefect-gcp,prefect-dbt"
load_mmb_publish_allowlist
validate_mmb_publish_allowlist && assert_eq "validate ok" "0" "0" || { echo "FAIL: validate ok"; failures=$((failures + 1)); }

# --- validate unknown package ---
MMB_PUBLISH_INTEGRATIONS="prefect-not-real"
load_mmb_publish_allowlist
assert_fail "validate unknown package" validate_mmb_publish_allowlist

# --- partition / filter ---
MMB_PUBLISH_INTEGRATIONS="prefect-gcp,prefect-dbt"
load_mmb_publish_allowlist
discovered=(prefect-aws prefect-gcp prefect-gitlab prefect-dbt prefect-slack)
mmb_partition_integrations_for_publish "${discovered[@]}"
assert_eq "publishable count" "2" "${#MMB_PUBLISHABLE_INTEGRATIONS[@]}"
assert_eq "publishable packages" "prefect-gcp prefect-dbt" "${MMB_PUBLISHABLE_INTEGRATIONS[*]}"
assert_eq "skipped count" "3" "${#MMB_SKIPPED_INTEGRATIONS[@]}"
assert_eq "skipped includes gitlab" "prefect-aws prefect-gitlab prefect-slack" "${MMB_SKIPPED_INTEGRATIONS[*]}"

# --- empty allowlist ---
MMB_PUBLISH_INTEGRATIONS=""
MMB_PUBLISH_INTEGRATIONS_CONF="${TMP_DIR}/empty.conf"
: > "$MMB_PUBLISH_INTEGRATIONS_CONF"
load_mmb_publish_allowlist
assert_eq "empty allowlist count" "0" "${#MMB_PUBLISH_ALLOWLIST[@]}"
discovered=(prefect-aws prefect-gcp)
mmb_partition_integrations_for_publish "${discovered[@]}"
assert_eq "empty allowlist publishable" "0" "${#MMB_PUBLISHABLE_INTEGRATIONS[@]}"
assert_eq "empty allowlist skipped all" "2" "${#MMB_SKIPPED_INTEGRATIONS[@]}"

if [[ "$failures" -gt 0 ]]; then
    echo "${failures} test(s) failed" >&2
    exit 1
fi
echo "All mmb-release-lib tests passed"
