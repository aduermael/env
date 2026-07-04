#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${DOCKERFILE:-${repo_root}/dev.Dockerfile}"
grok_npm_package="${GROK_NPM_PACKAGE:-@xai-official/grok}"
grok_cli_base_url="${GROK_CLI_BASE_URL:-https://x.ai/cli}"
requested_version="${1:-latest}"
cleanup_tmpdir=""

usage() {
    cat <<'EOF'
Usage: scripts/update-grok.sh [latest|VERSION]

Updates the Grok Build CLI pin in dev.Dockerfile.

Examples:
  scripts/update-grok.sh
  scripts/update-grok.sh 0.2.82

Environment:
  DOCKERFILE         Path to the Dockerfile to update. Defaults to dev.Dockerfile.
  GROK_NPM_PACKAGE  NPM package to query for latest. Defaults to @xai-official/grok.
  GROK_CLI_BASE_URL Base URL for raw Grok CLI binaries. Defaults to https://x.ai/cli.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

sha256_file() {
    local path="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$path" | awk '{print $1}'
    else
        die "required command not found: sha256sum or shasum"
    fi
}

validate_version() {
    local version="$1"
    [[ "$version" =~ ^[0-9][0-9A-Za-z._-]*$ ]] || die "unexpected Grok version: $version"
}

latest_release_version() {
    local package_path metadata version

    package_path="${grok_npm_package//@/%40}"
    package_path="${package_path//\//%2f}"
    metadata="$(curl -fsSL --retry 3 --retry-delay 2 "https://registry.npmjs.org/${package_path}/latest")"

    if command -v jq >/dev/null 2>&1; then
        version="$(printf '%s' "$metadata" | jq -r '.version // empty')"
    else
        version="$(
            printf '%s' "$metadata" |
                awk 'match($0, /"version":"[^"]+"/) { value = substr($0, RSTART, RLENGTH); sub(/^"version":"/, "", value); sub(/"$/, "", value); print value; exit }'
        )"
    fi

    [[ -n "$version" && "$version" != "null" ]] || die "could not resolve latest Grok release version"
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
            die "expected latest or a version like 0.2.82"
            ;;
    esac
}

download_asset() {
    local version="$1"
    local arch="$2"
    local output="$3"
    local asset url

    asset="grok-${version}-linux-${arch}"
    url="${grok_cli_base_url%/}/${asset}"

    printf 'download: %s\n' "$asset"
    curl -fsSL --retry 3 --retry-delay 2 -o "$output" "$url"
    [[ -s "$output" ]] || die "downloaded asset is empty: $asset"
    chmod +x "$output"
}

update_dockerfile() {
    local version="$1"
    local sha_amd64="$2"
    local sha_arm64="$3"
    local tmp

    [[ -f "$dockerfile" ]] || die "Dockerfile not found: $dockerfile"
    tmp="$(mktemp "${TMPDIR:-/tmp}/update-grok-dockerfile.XXXXXX")"

    awk \
        -v version="$version" \
        -v sha_amd64="$sha_amd64" \
        -v sha_arm64="$sha_arm64" \
        '
        /^ARG GROK_CLI_VERSION=/ {
            print "ARG GROK_CLI_VERSION=" version
            saw_version = 1
            next
        }
        /^ARG GROK_CLI_SHA256_AMD64=/ {
            print "ARG GROK_CLI_SHA256_AMD64=" sha_amd64
            saw_amd64 = 1
            next
        }
        /^ARG GROK_CLI_SHA256_ARM64=/ {
            print "ARG GROK_CLI_SHA256_ARM64=" sha_arm64
            saw_arm64 = 1
            next
        }
        { print }
        END {
            if (!saw_version || !saw_amd64 || !saw_arm64) {
                exit 1
            }
        }
        ' "$dockerfile" > "$tmp" || {
            rm -f "$tmp"
            die "could not update Grok ARGs in $dockerfile"
        }

    cp "$tmp" "$dockerfile"
    rm -f "$tmp"
}

smoke_check_host_binary() {
    local version="$1"
    local amd64_bin="$2"
    local arm64_bin="$3"
    local kernel arch target binary out

    kernel="$(uname -s)"
    arch="$(uname -m)"

    case "${kernel}/${arch}" in
        Linux/x86_64|Linux/amd64)
            target="x86_64"
            binary="$amd64_bin"
            ;;
        Linux/aarch64|Linux/arm64)
            target="aarch64"
            binary="$arm64_bin"
            ;;
        *)
            printf 'skip: host binary smoke check is only run on Linux amd64/arm64\n'
            return 0
            ;;
    esac

    out="$("$binary" --version)"
    [[ "$out" == "grok ${version}" || "$out" == "grok ${version} "* ]] || die "unexpected Grok version output: ${out}"
    printf 'ok: grok-%s --version -> %s\n' "$target" "$out"
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
    require_command curl
    require_command mktemp

    local version tmpdir amd64_bin arm64_bin sha_amd64 sha_arm64
    version="$(normalize_release_version "$requested_version")"

    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/update-grok.XXXXXX")"
    cleanup_tmpdir="$tmpdir"
    trap 'rm -rf "$cleanup_tmpdir"' EXIT

    printf 'release: %s\n' "$version"
    amd64_bin="${tmpdir}/grok-linux-x86_64"
    arm64_bin="${tmpdir}/grok-linux-aarch64"

    download_asset "$version" "x86_64" "$amd64_bin"
    download_asset "$version" "aarch64" "$arm64_bin"

    sha_amd64="$(sha256_file "$amd64_bin")"
    sha_arm64="$(sha256_file "$arm64_bin")"

    update_dockerfile "$version" "$sha_amd64" "$sha_arm64"
    smoke_check_host_binary "$version" "$amd64_bin" "$arm64_bin"

    printf 'updated: %s\n' "$dockerfile"
    printf 'GROK_CLI_VERSION=%s\n' "$version"
    printf 'GROK_CLI_SHA256_AMD64=%s\n' "$sha_amd64"
    printf 'GROK_CLI_SHA256_ARM64=%s\n' "$sha_arm64"
}

main "$@"
