#!/bin/bash
# Unit-style tests for release-version-lib.sh (no git required for most cases).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/release-version-lib.sh
source "${SCRIPT_DIR}/release-version-lib.sh"

failures=0

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

# normalize
assert_eq "strip mmb suffix" "3.7.2" "$(release_version_normalize_tag "3.7.2-mmb")"
assert_eq "no suffix unchanged" "3.7.2" "$(release_version_normalize_tag "3.7.2")"

# valid base
release_version_valid_base "3.7.2" true && assert_eq "strict ok" "0" "0" || { echo "FAIL: strict ok"; failures=$((failures + 1)); }
assert_fail "strict rejects dev" release_version_valid_base "3.7.2.dev1" true
release_version_valid_base "3.7.2.dev1" false && assert_eq "loose dev ok" "0" "0" || { echo "FAIL: loose dev"; failures=$((failures + 1)); }

# apply post
assert_eq "no post" "3.7.2" "$(release_version_apply_post "3.7.2" "")"
assert_eq "post1" "3.7.2.post1" "$(release_version_apply_post "3.7.2" "1")"
assert_fail "invalid post" release_version_apply_post "3.7.2" "x"

# override resolution (no git)
BASE_VERSION_OVERRIDE="3.7.2"
VERSION_POST="1"
FORCE_RELEASE_VERSION="false"
assert_eq "override with post" "3.7.2.post1" "$(release_version_resolve_prefect_core)"
BASE_VERSION_OVERRIDE=""
VERSION_POST=""

if [[ -d "${SCRIPT_DIR}/../.git" ]]; then
    cd "${SCRIPT_DIR}/.."
    if git rev-parse HEAD >/dev/null 2>&1; then
        if resolved=$(release_version_resolve_prefect_base 2>/dev/null); then
            echo "OK: git resolve base -> ${resolved}"
        else
            echo "SKIP: git resolve base (no matching tag on HEAD)"
        fi
    fi
fi

if [[ "$failures" -gt 0 ]]; then
    echo "${failures} test(s) failed" >&2
    exit 1
fi
echo "All release-version-lib tests passed"
