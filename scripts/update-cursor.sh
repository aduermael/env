#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${DOCKERFILE:-${repo_root}/dev.Dockerfile}"
cursor_install_url="${CURSOR_INSTALL_URL:-https://cursor.com/install}"
cursor_cli_base_url="${CURSOR_CLI_BASE_URL:-https://downloads.cursor.com/lab}"
requested_version="${1:-latest}"
cleanup_tmpdir=""

usage() {
    cat <<'EOF'
Usage: scripts/update-cursor.sh [latest|VERSION]

Updates the Cursor CLI release pin in dev.Dockerfile.

Examples:
  scripts/update-cursor.sh
  scripts/update-cursor.sh 2026.07.16-899851b

Environment:
  DOCKERFILE          Path to the Dockerfile to update. Defaults to dev.Dockerfile.
  CURSOR_INSTALL_URL  Official installer URL used to resolve latest. Defaults to https://cursor.com/install.
  CURSOR_CLI_BASE_URL Base URL for Cursor CLI release assets. Defaults to https://downloads.cursor.com/lab.
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
    [[ "$version" =~ ^[0-9][0-9A-Za-z._-]*$ ]] || die "unexpected Cursor CLI version: $version"
}

latest_release_version() {
    local installer version

    installer="$(curl -fsSL --retry 3 --retry-delay 2 "$cursor_install_url")"
    version="$(
        printf '%s\n' "$installer" |
            sed -n 's#^DOWNLOAD_URL="[^" ]*/lab/\([^/" ]*\)/.*#\1#p' |
            awk 'NR == 1 { print; exit }'
    )"

    [[ -n "$version" ]] || die "could not resolve latest Cursor CLI release from ${cursor_install_url}"
    validate_version "$version"
    printf '%s\n' "$version"
}

normalize_release_version() {
    local input="$1"
    case "$input" in
        latest|"")
            latest_release_version
            ;;
        [0-9]*)
            validate_version "$input"
            printf '%s\n' "$input"
            ;;
        *)
            die "expected latest or a version like 2026.07.16-899851b"
            ;;
    esac
}

download_asset() {
    local version="$1"
    local arch="$2"
    local output="$3"
    local asset url

    asset="cursor-agent-${version}-linux-${arch}.tar.gz"
    url="${cursor_cli_base_url%/}/${version}/linux/${arch}/agent-cli-package.tar.gz"

    printf 'download: %s\n' "$asset"
    curl -fsSL --retry 3 --retry-delay 2 -o "$output" "$url"
    tar -tzf "$output" |
        awk '$0 ~ /^[^/]+\/cursor-agent$/ { found = 1 } END { exit !found }' ||
        die "asset ${asset} does not contain cursor-agent"
}

update_dockerfile() {
    local version="$1"
    local sha_amd64="$2"
    local sha_arm64="$3"
    local tmp

    [[ -f "$dockerfile" ]] || die "Dockerfile not found: $dockerfile"
    tmp="$(mktemp "${TMPDIR:-/tmp}/update-cursor-dockerfile.XXXXXX")"

    awk \
        -v version="$version" \
        -v sha_amd64="$sha_amd64" \
        -v sha_arm64="$sha_arm64" \
        '
        /^ARG CURSOR_CLI_VERSION=/ {
            print "ARG CURSOR_CLI_VERSION=" version
            saw_version = 1
            next
        }
        /^ARG CURSOR_CLI_SHA256_AMD64=/ {
            print "ARG CURSOR_CLI_SHA256_AMD64=" sha_amd64
            saw_amd64 = 1
            next
        }
        /^ARG CURSOR_CLI_SHA256_ARM64=/ {
            print "ARG CURSOR_CLI_SHA256_ARM64=" sha_arm64
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
            die "could not update Cursor CLI ARGs in $dockerfile"
        }

    cp "$tmp" "$dockerfile"
    rm -f "$tmp"
}

smoke_check_host_binary() {
    local version="$1"
    local tmpdir="$2"
    local amd64_tar="$3"
    local arm64_tar="$4"
    local kernel arch target tarball out smoke_dir

    kernel="$(uname -s)"
    arch="$(uname -m)"

    case "${kernel}/${arch}" in
        Linux/x86_64|Linux/amd64)
            target="x64"
            tarball="$amd64_tar"
            ;;
        Linux/aarch64|Linux/arm64)
            target="arm64"
            tarball="$arm64_tar"
            ;;
        *)
            printf 'skip: host binary smoke check is only run on Linux amd64/arm64\n'
            return 0
            ;;
    esac

    smoke_dir="${tmpdir}/smoke"
    mkdir -p "$smoke_dir"
    tar --no-same-owner --strip-components=1 -xzf "$tarball" -C "$smoke_dir"
    out="$("${smoke_dir}/cursor-agent" --version)"
    [[ "$out" == "$version" ]] || die "unexpected Cursor CLI version output: ${out}"
    printf 'ok: cursor-agent-%s --version -> %s\n' "$target" "$out"
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
    require_command sed
    require_command tar

    local version tmpdir amd64_tar arm64_tar sha_amd64 sha_arm64
    version="$(normalize_release_version "$requested_version")"

    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/update-cursor.XXXXXX")"
    cleanup_tmpdir="$tmpdir"
    trap 'rm -rf "$cleanup_tmpdir"' EXIT

    printf 'release: %s\n' "$version"
    amd64_tar="${tmpdir}/cursor-linux-x64.tar.gz"
    arm64_tar="${tmpdir}/cursor-linux-arm64.tar.gz"

    download_asset "$version" "x64" "$amd64_tar"
    download_asset "$version" "arm64" "$arm64_tar"

    sha_amd64="$(sha256_file "$amd64_tar")"
    sha_arm64="$(sha256_file "$arm64_tar")"

    update_dockerfile "$version" "$sha_amd64" "$sha_arm64"
    smoke_check_host_binary "$version" "$tmpdir" "$amd64_tar" "$arm64_tar"

    printf 'updated: %s\n' "$dockerfile"
    printf 'CURSOR_CLI_VERSION=%s\n' "$version"
    printf 'CURSOR_CLI_SHA256_AMD64=%s\n' "$sha_amd64"
    printf 'CURSOR_CLI_SHA256_ARM64=%s\n' "$sha_arm64"
}

main "$@"
