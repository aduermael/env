#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${DOCKERFILE:-${repo_root}/dev.Dockerfile}"
kubectl_release_base_url="${KUBECTL_RELEASE_BASE_URL:-https://dl.k8s.io/release}"
requested_version="${1:-latest}"
cleanup_tmpdir=""

usage() {
    cat <<'EOF'
Usage: scripts/update-kubectl.sh [latest|VERSION]

Updates the kubectl pin in dev.Dockerfile.

Examples:
  scripts/update-kubectl.sh
  scripts/update-kubectl.sh v1.37.0
  scripts/update-kubectl.sh 1.37.0

Environment:
  DOCKERFILE                Path to the Dockerfile to update. Defaults to dev.Dockerfile.
  KUBECTL_RELEASE_BASE_URL  Base URL for versioned kubectl binaries. Defaults to https://dl.k8s.io/release.
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
    [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected kubectl version: $version"
}

latest_release_version() {
    local version

    version="$(curl -fsSL --retry 3 --retry-delay 2 "${kubectl_release_base_url%/}/stable.txt" | tr -d '[:space:]')"
    [[ -n "$version" ]] || die "could not resolve latest kubectl version from ${kubectl_release_base_url%/}/stable.txt"
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
            validate_version "$input"
            printf '%s\n' "$input"
            ;;
        [0-9]*)
            validate_version "v${input}"
            printf 'v%s\n' "$input"
            ;;
        *)
            die "expected latest or a version like v1.37.0"
            ;;
    esac
}

download_asset() {
    local version="$1"
    local arch="$2"
    local output="$3"
    local url expected actual

    url="${kubectl_release_base_url%/}/${version}/bin/linux/${arch}/kubectl"

    printf 'download: kubectl-%s-linux-%s\n' "$version" "$arch"
    curl -fsSL --retry 3 --retry-delay 2 -o "$output" "$url"
    [[ -s "$output" ]] || die "downloaded asset is empty: kubectl ${version} linux/${arch}"
    chmod +x "$output"

    expected="$(curl -fsSL --retry 3 --retry-delay 2 "${url}.sha256" | awk '{print $1}')"
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "unexpected official checksum for kubectl ${version} linux/${arch}: ${expected}"
    actual="$(sha256_file "$output")"
    [[ "$actual" == "$expected" ]] ||
        die "kubectl ${version} linux/${arch} digest mismatch (official ${expected}, got ${actual})"
}

update_dockerfile() {
    local version="$1"
    local sha_amd64="$2"
    local sha_arm64="$3"
    local tmp

    [[ -f "$dockerfile" ]] || die "Dockerfile not found: $dockerfile"
    tmp="$(mktemp "${TMPDIR:-/tmp}/update-kubectl-dockerfile.XXXXXX")"

    awk \
        -v version="$version" \
        -v sha_amd64="$sha_amd64" \
        -v sha_arm64="$sha_arm64" \
        '
        /^ARG KUBECTL_VERSION=/ {
            print "ARG KUBECTL_VERSION=" version
            saw_version = 1
            next
        }
        /^ARG KUBECTL_SHA256_AMD64=/ {
            print "ARG KUBECTL_SHA256_AMD64=" sha_amd64
            saw_amd64 = 1
            next
        }
        /^ARG KUBECTL_SHA256_ARM64=/ {
            print "ARG KUBECTL_SHA256_ARM64=" sha_arm64
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
            die "could not update kubectl ARGs in $dockerfile"
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
            target="amd64"
            binary="$amd64_bin"
            ;;
        Linux/aarch64|Linux/arm64)
            target="arm64"
            binary="$arm64_bin"
            ;;
        *)
            printf 'skip: host binary smoke check is only run on Linux amd64/arm64\n'
            return 0
            ;;
    esac

    out="$("$binary" version --client=true)"
    printf '%s\n' "$out" | grep -Fq "Client Version: ${version}" ||
        die "unexpected kubectl version output: ${out}"
    printf 'ok: kubectl-%s version --client -> %s\n' "$target" "$(printf '%s\n' "$out" | head -n 1)"
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
    require_command grep

    local version tmpdir amd64_bin arm64_bin sha_amd64 sha_arm64
    version="$(normalize_release_version "$requested_version")"

    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/update-kubectl.XXXXXX")"
    cleanup_tmpdir="$tmpdir"
    trap 'rm -rf "$cleanup_tmpdir"' EXIT

    printf 'release: %s\n' "$version"
    amd64_bin="${tmpdir}/kubectl-linux-amd64"
    arm64_bin="${tmpdir}/kubectl-linux-arm64"

    download_asset "$version" "amd64" "$amd64_bin"
    download_asset "$version" "arm64" "$arm64_bin"

    sha_amd64="$(sha256_file "$amd64_bin")"
    sha_arm64="$(sha256_file "$arm64_bin")"

    update_dockerfile "$version" "$sha_amd64" "$sha_arm64"
    smoke_check_host_binary "$version" "$amd64_bin" "$arm64_bin"

    printf 'updated: %s\n' "$dockerfile"
    printf 'KUBECTL_VERSION=%s\n' "$version"
    printf 'KUBECTL_SHA256_AMD64=%s\n' "$sha_amd64"
    printf 'KUBECTL_SHA256_ARM64=%s\n' "$sha_arm64"
}

main "$@"
