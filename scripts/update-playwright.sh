#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${DOCKERFILE:-${repo_root}/dev.Dockerfile}"
playwright_npm_tag="${PLAYWRIGHT_NPM_TAG:-latest}"
playwright_npm_registry="${PLAYWRIGHT_NPM_REGISTRY:-https://registry.npmjs.org}"
requested_version="${1:-latest}"

usage() {
    cat <<'EOF'
Usage: scripts/update-playwright.sh [latest|VERSION]

Updates the Playwright pin in dev.Dockerfile. The image runs
`playwright install-deps chromium webkit` at that version, so the pin
selects the browser system libraries installed in the image.

Examples:
  scripts/update-playwright.sh
  scripts/update-playwright.sh 1.58.2

Environment:
  DOCKERFILE                Path to the Dockerfile to update. Defaults to dev.Dockerfile.
  PLAYWRIGHT_NPM_TAG        NPM dist-tag to query for latest. Defaults to latest.
  PLAYWRIGHT_NPM_REGISTRY   NPM registry base URL. Defaults to https://registry.npmjs.org.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

validate_version() {
    local version="$1"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected Playwright version: $version"
}

latest_release_version() {
    local metadata version

    require_command curl
    metadata="$(curl -fsSL --retry 3 --retry-delay 2 "${playwright_npm_registry%/}/playwright/${playwright_npm_tag}")"

    if command -v jq >/dev/null 2>&1; then
        version="$(printf '%s' "$metadata" | jq -r '.version // empty')"
    else
        version="$(
            printf '%s' "$metadata" |
                awk 'match($0, /"version":"[^"]+"/) { value = substr($0, RSTART, RLENGTH); sub(/^"version":"/, "", value); sub(/"$/, "", value); print value; exit }'
        )"
    fi

    [[ -n "$version" && "$version" != "null" ]] || die "could not resolve latest Playwright version from npm dist-tag ${playwright_npm_tag}"
    validate_version "$version"
    printf '%s\n' "$version"
}

normalize_release_version() {
    local input="$1"
    case "$input" in
        latest|"")
            latest_release_version
            ;;
        v[0-9]*)
            input="${input#v}"
            validate_version "$input"
            printf '%s\n' "$input"
            ;;
        [0-9]*)
            validate_version "$input"
            printf '%s\n' "$input"
            ;;
        *)
            die "expected latest or a version like 1.58.2"
            ;;
    esac
}

update_dockerfile() {
    local version="$1"
    local tmp

    [[ -f "$dockerfile" ]] || die "Dockerfile not found: $dockerfile"
    tmp="$(mktemp "${TMPDIR:-/tmp}/update-playwright-dockerfile.XXXXXX")"

    awk \
        -v version="$version" \
        '
        /^ARG PLAYWRIGHT_VERSION=/ {
            print "ARG PLAYWRIGHT_VERSION=" version
            saw_version = 1
            next
        }
        { print }
        END {
            if (!saw_version) {
                exit 1
            }
        }
        ' "$dockerfile" > "$tmp" || {
            rm -f "$tmp"
            die "could not update PLAYWRIGHT_VERSION in $dockerfile"
        }

    cp "$tmp" "$dockerfile"
    rm -f "$tmp"
}

main() {
    if [[ "$#" -gt 1 ]]; then
        usage
        die "expected at most one argument"
    fi

    if [[ "${requested_version}" == "-h" || "${requested_version}" == "--help" ]]; then
        usage
        exit 0
    fi

    require_command awk
    require_command mktemp

    local version
    version="$(normalize_release_version "$requested_version")"

    printf 'release: %s\n' "$version"
    update_dockerfile "$version"

    printf 'updated: %s\n' "$dockerfile"
    printf 'PLAYWRIGHT_VERSION=%s\n' "$version"
}

main "$@"
