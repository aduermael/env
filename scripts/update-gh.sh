#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${DOCKERFILE:-${repo_root}/dev.Dockerfile}"
github_cli_release_base_url="${GITHUB_CLI_RELEASE_BASE_URL:-https://github.com/cli/cli/releases/download}"
github_cli_latest_url="${GITHUB_CLI_LATEST_URL:-https://github.com/cli/cli/releases/latest}"
requested_version="${1:-latest}"
cleanup_tmpdir=""

usage() {
    cat <<'EOF'
Usage: scripts/update-gh.sh [latest|VERSION]

Updates the GitHub CLI (gh) pin in dev.Dockerfile.
Without a version, tracks the newest stable release.

Examples:
  scripts/update-gh.sh
  scripts/update-gh.sh 2.98.0
  scripts/update-gh.sh v2.98.0

Environment:
  DOCKERFILE                   Path to the Dockerfile to update. Defaults to dev.Dockerfile.
  GITHUB_CLI_RELEASE_BASE_URL  Base URL for versioned GitHub CLI release assets.
                               Defaults to https://github.com/cli/cli/releases/download.
  GITHUB_CLI_LATEST_URL        URL whose final redirect names the newest stable release.
                               Defaults to https://github.com/cli/cli/releases/latest.
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
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected GitHub CLI version: $version"
}

latest_release_version() {
    local url tag version

    url="$(curl -fsSL --retry 3 --retry-delay 2 -o /dev/null -w '%{url_effective}' "$github_cli_latest_url")"
    tag="${url##*/}"
    tag="${tag%%\?*}"
    [[ "$tag" == v* ]] || die "could not resolve latest GitHub CLI release from ${url}"
    version="${tag#v}"
    validate_version "$version"
    printf '%s\n' "$version"
}

normalize_release_version() {
    local input="$1"
    local stripped
    case "$input" in
        latest|"")
            latest_release_version
            ;;
        v*)
            stripped="${input#v}"
            validate_version "$stripped"
            printf '%s\n' "$stripped"
            ;;
        *)
            validate_version "$input"
            printf '%s\n' "$input"
            ;;
    esac
}

official_checksum() {
    local checksums_file="$1"
    local asset="$2"
    local expected

    expected="$(awk -v asset="$asset" '$2 == asset { print $1; found = 1 } END { exit !found }' "$checksums_file")" ||
        die "checksums file does not list ${asset}"
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "unexpected official checksum for ${asset}: ${expected}"
    printf '%s\n' "$expected"
}

download_asset() {
    local version="$1"
    local arch="$2"
    local output="$3"
    local checksums_file="$4"
    local asset url expected actual

    asset="gh_${version}_linux_${arch}.tar.gz"
    url="${github_cli_release_base_url%/}/v${version}/${asset}"

    printf 'download: %s\n' "$asset"
    curl -fsSL --retry 3 --retry-delay 2 -o "$output" "$url"
    [[ -s "$output" ]] || die "downloaded asset is empty: ${asset}"
    tar -tzf "$output" | grep -Eq '(^|/)bin/gh$' ||
        die "asset ${asset} does not contain bin/gh"

    expected="$(official_checksum "$checksums_file" "$asset")"
    actual="$(sha256_file "$output")"
    [[ "$actual" == "$expected" ]] ||
        die "${asset} digest mismatch (official ${expected}, got ${actual})"
}

update_dockerfile() {
    local version="$1"
    local sha_amd64="$2"
    local sha_arm64="$3"
    local tmp

    [[ -f "$dockerfile" ]] || die "Dockerfile not found: $dockerfile"
    tmp="$(mktemp "${TMPDIR:-/tmp}/update-gh-dockerfile.XXXXXX")"

    awk \
        -v version="$version" \
        -v sha_amd64="$sha_amd64" \
        -v sha_arm64="$sha_arm64" \
        '
        /^ARG GITHUB_CLI_VERSION=/ {
            print "ARG GITHUB_CLI_VERSION=" version
            saw_version = 1
            next
        }
        /^ARG GITHUB_CLI_SHA256_AMD64=/ {
            print "ARG GITHUB_CLI_SHA256_AMD64=" sha_amd64
            saw_amd64 = 1
            next
        }
        /^ARG GITHUB_CLI_SHA256_ARM64=/ {
            print "ARG GITHUB_CLI_SHA256_ARM64=" sha_arm64
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
            die "could not update GitHub CLI ARGs in $dockerfile"
        }

    cp "$tmp" "$dockerfile"
    rm -f "$tmp"
}

smoke_check_host_binary() {
    local version="$1"
    local tmpdir="$2"
    local amd64_tar="$3"
    local arm64_tar="$4"
    local kernel arch target tarball smoke_dir out

    kernel="$(uname -s)"
    arch="$(uname -m)"

    case "${kernel}/${arch}" in
        Linux/x86_64|Linux/amd64)
            target="amd64"
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
    tar --no-same-owner -xzf "$tarball" -C "$smoke_dir" --strip-components=1
    out="$("${smoke_dir}/bin/gh" version 2>&1)"
    printf '%s\n' "$out" | grep -Fq "gh version ${version}" ||
        die "unexpected GitHub CLI version output: ${out}"
    printf 'ok: gh-%s version -> %s\n' "$target" "$(printf '%s\n' "$out" | head -n 1)"
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
    require_command grep
    require_command mktemp
    require_command tar

    local version tmpdir checksums_file amd64_tar arm64_tar sha_amd64 sha_arm64
    version="$(normalize_release_version "$requested_version")"

    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/update-gh.XXXXXX")"
    cleanup_tmpdir="$tmpdir"
    trap 'rm -rf "$cleanup_tmpdir"' EXIT

    printf 'release: %s\n' "$version"
    checksums_file="${tmpdir}/gh_${version}_checksums.txt"
    curl -fsSL --retry 3 --retry-delay 2 -o "$checksums_file" \
        "${github_cli_release_base_url%/}/v${version}/gh_${version}_checksums.txt"
    [[ -s "$checksums_file" ]] || die "downloaded checksums file is empty for GitHub CLI ${version}"

    amd64_tar="${tmpdir}/gh-linux-amd64.tar.gz"
    arm64_tar="${tmpdir}/gh-linux-arm64.tar.gz"

    download_asset "$version" "amd64" "$amd64_tar" "$checksums_file"
    download_asset "$version" "arm64" "$arm64_tar" "$checksums_file"

    sha_amd64="$(sha256_file "$amd64_tar")"
    sha_arm64="$(sha256_file "$arm64_tar")"

    update_dockerfile "$version" "$sha_amd64" "$sha_arm64"
    smoke_check_host_binary "$version" "$tmpdir" "$amd64_tar" "$arm64_tar"

    printf 'updated: %s\n' "$dockerfile"
    printf 'GITHUB_CLI_VERSION=%s\n' "$version"
    printf 'GITHUB_CLI_SHA256_AMD64=%s\n' "$sha_amd64"
    printf 'GITHUB_CLI_SHA256_ARM64=%s\n' "$sha_arm64"
}

main "$@"
