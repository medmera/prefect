#!/bin/bash
# Shared version resolution for MMB release scripts.
# Sourced by release-python-packages.sh and release-docker-images.sh — do not execute directly.
#
# Environment variables:
#   VERSION_POST              Core post number (e.g. 1 → .post1); empty = none
#   INTEGRATION_VERSION_POST  Integration post number; empty = none
#   BASE_VERSION_OVERRIDE     Force core base x.y.z before post suffix; empty = auto
#   FORCE_RELEASE_VERSION     If true, base must be strict x.y.z (no dev suffix on base)

: "${VERSION_POST:=}"
: "${INTEGRATION_VERSION_POST:=}"
: "${BASE_VERSION_OVERRIDE:=}"
: "${FORCE_RELEASE_VERSION:=false}"

# Strip trailing -mmb from git describe results (MMB publish tags).
release_version_normalize_tag() {
    local tag="$1"
    tag="${tag%-mmb}"
    echo "$tag"
}

# Validate base version (before .postN is applied).
release_version_valid_base() {
    local version="$1"
    local strict="${2:-false}"
    if [[ -z "$version" ]]; then
        return 1
    fi
    if [[ "$strict" == "true" ]]; then
        echo "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'
    else
        echo "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+([.]?[a-zA-Z0-9]+)*$'
    fi
}

# Append PEP 440 .postN when post_n is non-empty.
release_version_apply_post() {
    local base="$1"
    local post_n="$2"
    if [[ -z "$post_n" ]]; then
        echo "$base"
        return 0
    fi
    if ! echo "$post_n" | grep -qE '^[0-9]+$'; then
        echo "INTEGRATION_VERSION_POST and VERSION_POST must be numeric (e.g. 1)" >&2
        return 1
    fi
    echo "${base}.post${post_n}"
}

# Resolve base prefect core version from override or git describe.
release_version_resolve_prefect_base() {
    local strict="false"
    if [[ "${FORCE_RELEASE_VERSION}" == "true" ]]; then
        strict="true"
    fi

    local base=""
    if [[ -n "${BASE_VERSION_OVERRIDE}" ]]; then
        base="${BASE_VERSION_OVERRIDE}"
        base=$(release_version_normalize_tag "$base")
        if ! release_version_valid_base "$base" "$strict"; then
            echo "Invalid BASE_VERSION_OVERRIDE: ${BASE_VERSION_OVERRIDE}" >&2
            return 1
        fi
        echo "$base"
        return 0
    fi

    local tag
    tag=$(git describe --tags --match "[0-9]*.[0-9]*.[0-9]*" --abbrev=0 HEAD 2>/dev/null) || true
    if [[ -z "$tag" ]]; then
        return 1
    fi
    base=$(release_version_normalize_tag "$tag")
    if ! release_version_valid_base "$base" "$strict"; then
        return 1
    fi
    echo "$base"
}

# Full prefect core version including optional .postN.
release_version_resolve_prefect_core() {
    local base
    base=$(release_version_resolve_prefect_base) || return 1
    release_version_apply_post "$base" "${VERSION_POST}"
}

# Integration package version from nearest ancestor tag.
release_version_resolve_integration() {
    local package_name="$1"
    local strict="false"
    if [[ "${FORCE_RELEASE_VERSION}" == "true" ]]; then
        strict="true"
    fi

    local tag
    tag=$(git describe --tags --match "${package_name}-*" --abbrev=0 HEAD 2>/dev/null) || true
    if [[ -z "$tag" ]]; then
        return 1
    fi

    local version="${tag#${package_name}-}"
    version=$(release_version_normalize_tag "$version")
    if ! release_version_valid_base "$version" "$strict"; then
        return 1
    fi
    release_version_apply_post "$version" "${INTEGRATION_VERSION_POST}"
}

# Log resolved version (callers may define log()).
release_version_log_resolved() {
    local package_label="$1"
    local full_version="$2"
    local base="$3"
    local post_n="$4"
    local msg="Resolved ${package_label} version: ${full_version} (base=${base}"
    if [[ -n "$post_n" ]]; then
        msg+=", post=${post_n}"
    fi
    msg+=")"
    if declare -f log >/dev/null 2>&1; then
        log "$msg" >&2
    else
        echo "$msg" >&2
    fi
}
