#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${DOCKERFILE:-${repo_root}/dev.Dockerfile}"
dagger_cli_base_url="${DAGGER_CLI_BASE_URL:-https://dl.dagger.io/dagger}"
requested_version="${1:-latest}"
cleanup_tmpdir=""

usage() {
    cat <<'EOF'
Usage: scripts/update-dagger.sh [latest|VERSION]

Updates the Dagger CLI pin in dev.Dockerfile.
Without a version, tracks the newest v1.0.0-beta.N release.
The stable 0.x channel at versions/latest is a different line.

Examples:
  scripts/update-dagger.sh
  scripts/update-dagger.sh v1.0.0-beta.15
  scripts/update-dagger.sh 1.0.0-beta.15

Environment:
  DOCKERFILE           Path to the Dockerfile to update. Defaults to dev.Dockerfile.
  DAGGER_CLI_BASE_URL  Base URL for Dagger CLI release archives.
                       Defaults to https://dl.dagger.io/dagger.
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
    [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$ ]] || die "unexpected Dagger CLI version: $version"
}

latest_release_version() {
    local best

    require_command git
    best="$(
        git ls-remote --tags https://github.com/dagger/dagger.git 'v1.0.0-beta.*' |
            awk '{ sub(/^.*\//, "", $2); print $2 }' |
            sed -n 's/^v1\.0\.0-beta\.\([0-9][0-9]*\)$/\1/p' |
            sort -n |
            tail -n 1
    )"
    [[ -n "$best" ]] || die "could not resolve latest Dagger CLI 1.0.0 beta"
    validate_version "v1.0.0-beta.${best}"
    printf 'v1.0.0-beta.%s\n' "$best"
}

normalize_release_version() {
    local input="$1"
    case "$input" in
        latest|"")
            latest_release_version
            ;;
        v[0-9]*)
            validate_version "$input"
            printf '%s\n' "$input"
            ;;
        [0-9]*)
            validate_version "v${input}"
            printf 'v%s\n' "$input"
            ;;
        *)
            die "expected latest or a version like v1.0.0-beta.15"
            ;;
    esac
}

official_checksum() {
    local checksums_file="$1"
    local asset="$2"
    local expected

    expected="$(awk -v asset="$asset" '$2 == asset { print $1; found = 1 } END { exit !found }' "$checksums_file")" ||
        die "checksums.txt does not list ${asset}"
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "unexpected official checksum for ${asset}: ${expected}"
    printf '%s\n' "$expected"
}

download_asset() {
    local version="$1"
    local arch="$2"
    local output="$3"
    local checksums_file="$4"
    local asset url expected actual

    asset="dagger_${version}_linux_${arch}.tar.gz"
    url="${dagger_cli_base_url%/}/releases/${version#v}/${asset}"

    printf 'download: %s\n' "$asset"
    curl -fsSL --retry 3 --retry-delay 2 -o "$output" "$url"
    [[ -s "$output" ]] || die "downloaded asset is empty: ${asset}"
    tar -tzf "$output" | grep -Fx 'dagger' >/dev/null ||
        die "asset ${asset} does not contain dagger"

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
    tmp="$(mktemp "${TMPDIR:-/tmp}/update-dagger-dockerfile.XXXXXX")"

    awk \
        -v version="$version" \
        -v sha_amd64="$sha_amd64" \
        -v sha_arm64="$sha_arm64" \
        '
        /^ARG DAGGER_CLI_VERSION=/ {
            print "ARG DAGGER_CLI_VERSION=" version
            saw_version = 1
            next
        }
        /^ARG DAGGER_CLI_SHA256_AMD64=/ {
            print "ARG DAGGER_CLI_SHA256_AMD64=" sha_amd64
            saw_amd64 = 1
            next
        }
        /^ARG DAGGER_CLI_SHA256_ARM64=/ {
            print "ARG DAGGER_CLI_SHA256_ARM64=" sha_arm64
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
            die "could not update Dagger CLI ARGs in $dockerfile"
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
    tar --no-same-owner -xzf "$tarball" -C "$smoke_dir"
    out="$("${smoke_dir}/dagger" version)"
    printf '%s\n' "$out" | grep -Fq "${version}" ||
        die "unexpected Dagger CLI version output: ${out}"
    printf 'ok: dagger-%s version -> %s\n' "$target" "$(printf '%s\n' "$out" | head -n 1)"
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

    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/update-dagger.XXXXXX")"
    cleanup_tmpdir="$tmpdir"
    trap 'rm -rf "$cleanup_tmpdir"' EXIT

    printf 'release: %s\n' "$version"
    checksums_file="${tmpdir}/checksums.txt"
    curl -fsSL --retry 3 --retry-delay 2 -o "$checksums_file" \
        "${dagger_cli_base_url%/}/releases/${version#v}/checksums.txt"
    [[ -s "$checksums_file" ]] || die "downloaded checksums.txt is empty for Dagger CLI ${version}"

    amd64_tar="${tmpdir}/dagger-linux-amd64.tar.gz"
    arm64_tar="${tmpdir}/dagger-linux-arm64.tar.gz"

    download_asset "$version" "amd64" "$amd64_tar" "$checksums_file"
    download_asset "$version" "arm64" "$arm64_tar" "$checksums_file"

    sha_amd64="$(sha256_file "$amd64_tar")"
    sha_arm64="$(sha256_file "$arm64_tar")"

    update_dockerfile "$version" "$sha_amd64" "$sha_arm64"
    smoke_check_host_binary "$version" "$tmpdir" "$amd64_tar" "$arm64_tar"

    printf 'updated: %s\n' "$dockerfile"
    printf 'DAGGER_CLI_VERSION=%s\n' "$version"
    printf 'DAGGER_CLI_SHA256_AMD64=%s\n' "$sha_amd64"
    printf 'DAGGER_CLI_SHA256_ARM64=%s\n' "$sha_arm64"
}

main "$@"
