#!/bin/bash
#
# MMB release helpers: integration publish allowlist.
# Sourced by release-python-packages.sh and test-mmb-release-lib.sh.
#
# Config: scripts/mmb-publish-integrations.conf (default)
# Override (local testing): MMB_PUBLISH_INTEGRATIONS=prefect-gcp,prefect-dbt

MMB_PUBLISH_INTEGRATIONS_CONF="${MMB_PUBLISH_INTEGRATIONS_CONF:-scripts/mmb-publish-integrations.conf}"
MMB_PUBLISH_ALLOWLIST=()
MMB_PUBLISHABLE_INTEGRATIONS=()
MMB_SKIPPED_INTEGRATIONS=()

_mmb_trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

# Populates MMB_PUBLISH_ALLOWLIST (may be empty).
load_mmb_publish_allowlist() {
    MMB_PUBLISH_ALLOWLIST=()

    if [[ -n "${MMB_PUBLISH_INTEGRATIONS:-}" ]]; then
        local item
        local IFS=','
        for item in $MMB_PUBLISH_INTEGRATIONS; do
            item="$(_mmb_trim "$item")"
            [[ -n "$item" ]] && MMB_PUBLISH_ALLOWLIST+=("$item")
        done
        return 0
    fi

    if [[ ! -f "$MMB_PUBLISH_INTEGRATIONS_CONF" ]]; then
        return 0
    fi

    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="$(_mmb_trim "$line")"
        [[ -n "$line" ]] && MMB_PUBLISH_ALLOWLIST+=("$line")
    done < "$MMB_PUBLISH_INTEGRATIONS_CONF"
}

# Exit 1 if any allowlisted name is missing from src/integrations/.
validate_mmb_publish_allowlist() {
    local pkg
    for pkg in "${MMB_PUBLISH_ALLOWLIST[@]}"; do
        if [[ ! -d "src/integrations/${pkg}" ]]; then
            echo "Allowlisted integration not found: ${pkg} (expected src/integrations/${pkg}/)" >&2
            return 1
        fi
    done
}

# Return 0 if package is in MMB_PUBLISH_ALLOWLIST (call load_mmb_publish_allowlist first).
mmb_is_allowlisted_integration() {
    local package="$1"
    local allow

    if [[ ${#MMB_PUBLISH_ALLOWLIST[@]} -eq 0 ]]; then
        return 1
    fi

    for allow in "${MMB_PUBLISH_ALLOWLIST[@]}"; do
        if [[ "$package" == "$allow" ]]; then
            return 0
        fi
    done
    return 1
}

# Partition discovered integration names into MMB_PUBLISHABLE_INTEGRATIONS and
# MMB_SKIPPED_INTEGRATIONS (preserves discovery order for publishable).
mmb_partition_integrations_for_publish() {
    local package

    MMB_PUBLISHABLE_INTEGRATIONS=()
    MMB_SKIPPED_INTEGRATIONS=()

    load_mmb_publish_allowlist

    for package in "$@"; do
        if mmb_is_allowlisted_integration "$package"; then
            MMB_PUBLISHABLE_INTEGRATIONS+=("$package")
        else
            MMB_SKIPPED_INTEGRATIONS+=("$package")
        fi
    done
}
