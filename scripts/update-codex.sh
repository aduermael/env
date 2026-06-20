#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${DOCKERFILE:-${repo_root}/dev.Dockerfile}"
codex_repo="${CODEX_REPO:-openai/codex}"
requested_version="${1:-latest}"
cleanup_tmpdir=""

usage() {
    cat <<'EOF'
Usage: scripts/update-codex.sh [latest|VERSION|TAG]

Updates the Codex release pin in dev.Dockerfile.

Examples:
  scripts/update-codex.sh
  scripts/update-codex.sh 0.141.0
  scripts/update-codex.sh rust-v0.141.0

Environment:
  DOCKERFILE   Path to the Dockerfile to update. Defaults to dev.Dockerfile.
  CODEX_REPO   GitHub repo to query. Defaults to openai/codex.
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

latest_release_tag() {
    local url tag
    url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/${codex_repo}/releases/latest")"
    tag="${url##*/}"
    tag="${tag%%\?*}"
    [[ -n "$tag" && "$tag" != "latest" ]] || die "could not resolve latest Codex release tag"
    printf '%s\n' "$tag"
}

normalize_release_tag() {
    local input="$1"
    case "$input" in
        latest|"")
            latest_release_tag
            ;;
        rust-v*)
            printf '%s\n' "$input"
            ;;
        v[0-9]*)
            printf 'rust-%s\n' "$input"
            ;;
        [0-9]*)
            printf 'rust-v%s\n' "$input"
            ;;
        *)
            die "expected latest, a version like 0.141.0, or a tag like rust-v0.141.0"
            ;;
    esac
}

download_asset() {
    local tag="$1"
    local target="$2"
    local output="$3"
    local asset="codex-${target}.tar.gz"
    local url="https://github.com/${codex_repo}/releases/download/${tag}/${asset}"

    printf 'download: %s\n' "$asset"
    curl -fsSL --retry 3 --retry-delay 2 -o "$output" "$url"
    tar -tzf "$output" | grep -Fxq "codex-${target}" || die "asset ${asset} does not contain codex-${target}"
}

update_dockerfile() {
    local tag="$1"
    local sha_amd64="$2"
    local sha_arm64="$3"
    local tmp

    [[ -f "$dockerfile" ]] || die "Dockerfile not found: $dockerfile"
    tmp="$(mktemp "${TMPDIR:-/tmp}/update-codex-dockerfile.XXXXXX")"

    awk \
        -v tag="$tag" \
        -v sha_amd64="$sha_amd64" \
        -v sha_arm64="$sha_arm64" \
        '
        /^ARG CODEX_VERSION=/ {
            print "ARG CODEX_VERSION=" tag
            saw_version = 1
            next
        }
        /^ARG CODEX_SHA256_AMD64=/ {
            print "ARG CODEX_SHA256_AMD64=" sha_amd64
            saw_amd64 = 1
            next
        }
        /^ARG CODEX_SHA256_ARM64=/ {
            print "ARG CODEX_SHA256_ARM64=" sha_arm64
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
            die "could not update Codex ARGs in $dockerfile"
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
            target="x86_64-unknown-linux-musl"
            tarball="$amd64_tar"
            ;;
        Linux/aarch64|Linux/arm64)
            target="aarch64-unknown-linux-musl"
            tarball="$arm64_tar"
            ;;
        *)
            printf 'skip: host binary smoke check is only run on Linux amd64/arm64\n'
            return 0
            ;;
    esac

    smoke_dir="${tmpdir}/smoke"
    mkdir -p "$smoke_dir"
    tar -xzf "$tarball" -C "$smoke_dir"
    out="$("${smoke_dir}/codex-${target}" --version)"
    [[ "$out" == "codex-cli ${version}" ]] || die "unexpected Codex version output: ${out}"
    printf 'ok: %s --version -> %s\n' "codex-${target}" "$out"
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

    local tag version tmpdir amd64_tar arm64_tar sha_amd64 sha_arm64
    tag="$(normalize_release_tag "$requested_version")"
    version="${tag#rust-v}"
    [[ "$tag" == rust-v* ]] || die "Codex release tag must start with rust-v: $tag"

    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/update-codex.XXXXXX")"
    cleanup_tmpdir="$tmpdir"
    trap 'rm -rf "$cleanup_tmpdir"' EXIT

    printf 'release: %s\n' "$tag"
    amd64_tar="${tmpdir}/codex-x86_64-unknown-linux-musl.tar.gz"
    arm64_tar="${tmpdir}/codex-aarch64-unknown-linux-musl.tar.gz"

    download_asset "$tag" "x86_64-unknown-linux-musl" "$amd64_tar"
    download_asset "$tag" "aarch64-unknown-linux-musl" "$arm64_tar"

    sha_amd64="$(sha256_file "$amd64_tar")"
    sha_arm64="$(sha256_file "$arm64_tar")"

    update_dockerfile "$tag" "$sha_amd64" "$sha_arm64"
    smoke_check_host_binary "$version" "$tmpdir" "$amd64_tar" "$arm64_tar"

    printf 'updated: %s\n' "$dockerfile"
    printf 'CODEX_VERSION=%s\n' "$tag"
    printf 'CODEX_SHA256_AMD64=%s\n' "$sha_amd64"
    printf 'CODEX_SHA256_ARM64=%s\n' "$sha_arm64"
}

main "$@"
