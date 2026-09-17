#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${DOCKERFILE:-${repo_root}/dev.Dockerfile}"
plugin_rapid_components_url="${GKE_GCLOUD_AUTH_PLUGIN_RAPID_COMPONENTS_URL:-https://dl.google.com/dl/cloudsdk/channels/rapid/components-2.json}"
plugin_base_url="${GKE_GCLOUD_AUTH_PLUGIN_BASE_URL:-https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/for_packagers/linux}"
requested_version="${1:-latest}"
cleanup_tmpdir=""

usage() {
    cat <<'EOF'
Usage: scripts/update-gke-gcloud-auth-plugin.sh [latest|VERSION]

Updates the gke-gcloud-auth-plugin pin in dev.Dockerfile to a rapid-channel
Google Cloud CLI packager archive.

Examples:
  scripts/update-gke-gcloud-auth-plugin.sh
  scripts/update-gke-gcloud-auth-plugin.sh 585.0.0

Environment:
  DOCKERFILE                                Path to the Dockerfile to update. Defaults to dev.Dockerfile.
  GKE_GCLOUD_AUTH_PLUGIN_RAPID_COMPONENTS_URL  Rapid-channel metadata JSON used to resolve latest.
  GKE_GCLOUD_AUTH_PLUGIN_BASE_URL           Base URL for versioned linux packager archives.
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
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected gke-gcloud-auth-plugin version: $version"
}

latest_release_version() {
    local metadata version

    metadata="$(curl -fsSL --retry 3 --retry-delay 2 "$plugin_rapid_components_url")"
    [[ -n "$metadata" ]] || die "could not fetch rapid-channel metadata from ${plugin_rapid_components_url}"

    if command -v jq >/dev/null 2>&1; then
        version="$(printf '%s' "$metadata" | jq -r '.version // empty')"
    else
        version="$(
            printf '%s' "$metadata" |
                grep -oE '"version": "[0-9]+\.[0-9]+\.[0-9]+"' |
                head -n 1 |
                sed -n 's/^"version": "\([^"]*\)"$/\1/p'
        )"
    fi

    [[ -n "$version" && "$version" != "null" ]] || die "could not resolve latest gke-gcloud-auth-plugin version from ${plugin_rapid_components_url}"
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
            die "expected latest or a version like 585.0.0"
            ;;
    esac
}

archive_version() {
    local archive="$1"
    local snapshot version

    snapshot="$(tar -xOf "$archive" google-cloud-sdk/.install/gke-gcloud-auth-plugin.snapshot.json)"
    [[ -n "$snapshot" ]] || die "asset does not contain gke-gcloud-auth-plugin.snapshot.json"

    if command -v jq >/dev/null 2>&1; then
        version="$(printf '%s' "$snapshot" | jq -r '.version // empty')"
    else
        version="$(
            printf '%s' "$snapshot" |
                grep -oE '"version": "[0-9]+\.[0-9]+\.[0-9]+"' |
                head -n 1 |
                sed -n 's/^"version": "\([^"]*\)"$/\1/p'
        )"
    fi

    [[ -n "$version" && "$version" != "null" ]] || die "could not read snapshot version from ${archive}"
    printf '%s\n' "$version"
}

download_asset() {
    local version="$1"
    local arch="$2"
    local output="$3"
    local asset url sdk_version

    asset="google-cloud-cli-gke-gcloud-auth-plugin_${version}.orig_${arch}.tar.gz"
    url="${plugin_base_url%/}/${asset}"

    printf 'download: %s\n' "$asset"
    curl -fsSL --retry 3 --retry-delay 2 -o "$output" "$url"
    tar -tzf "$output" google-cloud-sdk/bin/gke-gcloud-auth-plugin >/dev/null ||
        die "asset ${asset} does not contain google-cloud-sdk/bin/gke-gcloud-auth-plugin"

    sdk_version="$(archive_version "$output")"
    [[ "$sdk_version" == "$version" ]] ||
        die "asset ${asset} snapshot version is ${sdk_version}, expected ${version}"
}

update_dockerfile() {
    local version="$1"
    local sha_amd64="$2"
    local sha_arm64="$3"
    local tmp

    [[ -f "$dockerfile" ]] || die "Dockerfile not found: $dockerfile"
    tmp="$(mktemp "${TMPDIR:-/tmp}/update-gke-gcloud-auth-plugin-dockerfile.XXXXXX")"

    awk \
        -v version="$version" \
        -v sha_amd64="$sha_amd64" \
        -v sha_arm64="$sha_arm64" \
        '
        /^ARG GKE_GCLOUD_AUTH_PLUGIN_VERSION=/ {
            print "ARG GKE_GCLOUD_AUTH_PLUGIN_VERSION=" version
            saw_version = 1
            next
        }
        /^ARG GKE_GCLOUD_AUTH_PLUGIN_SHA256_AMD64=/ {
            print "ARG GKE_GCLOUD_AUTH_PLUGIN_SHA256_AMD64=" sha_amd64
            saw_amd64 = 1
            next
        }
        /^ARG GKE_GCLOUD_AUTH_PLUGIN_SHA256_ARM64=/ {
            print "ARG GKE_GCLOUD_AUTH_PLUGIN_SHA256_ARM64=" sha_arm64
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
            die "could not update gke-gcloud-auth-plugin ARGs in $dockerfile"
        }

    cp "$tmp" "$dockerfile"
    rm -f "$tmp"
}

smoke_check_host_binary() {
    local version="$1"
    local amd64_tar="$2"
    local arm64_tar="$3"
    local kernel arch target archive extract_dir binary out

    kernel="$(uname -s)"
    arch="$(uname -m)"

    case "${kernel}/${arch}" in
        Linux/x86_64|Linux/amd64)
            target="amd64"
            archive="$amd64_tar"
            ;;
        Linux/aarch64|Linux/arm64)
            target="aarch64"
            archive="$arm64_tar"
            ;;
        *)
            printf 'skip: host binary smoke check is only run on Linux amd64/arm64\n'
            return 0
            ;;
    esac

    extract_dir="$(mktemp -d "${TMPDIR:-/tmp}/gke-gcloud-auth-plugin-smoke.XXXXXX")"
    tar -xzf "$archive" -C "$extract_dir" google-cloud-sdk/bin/gke-gcloud-auth-plugin
    binary="${extract_dir}/google-cloud-sdk/bin/gke-gcloud-auth-plugin"
    [[ -x "$binary" ]] || die "extracted gke-gcloud-auth-plugin is not executable"
    out="$("$binary" --version)"
    [[ -n "$out" ]] || die "gke-gcloud-auth-plugin --version produced no output"
    printf 'ok: gke-gcloud-auth-plugin-%s --version -> %s\n' "$target" "$(printf '%s\n' "$out" | head -n 1)"
    rm -rf "$extract_dir"
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
    require_command tar

    local version tmpdir amd64_tar arm64_tar sha_amd64 sha_arm64
    version="$(normalize_release_version "$requested_version")"

    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/update-gke-gcloud-auth-plugin.XXXXXX")"
    cleanup_tmpdir="$tmpdir"
    trap 'rm -rf "$cleanup_tmpdir"' EXIT

    printf 'release: %s\n' "$version"
    amd64_tar="${tmpdir}/google-cloud-cli-gke-gcloud-auth-plugin-linux-amd64.tar.gz"
    arm64_tar="${tmpdir}/google-cloud-cli-gke-gcloud-auth-plugin-linux-aarch64.tar.gz"

    download_asset "$version" "amd64" "$amd64_tar"
    download_asset "$version" "aarch64" "$arm64_tar"

    sha_amd64="$(sha256_file "$amd64_tar")"
    sha_arm64="$(sha256_file "$arm64_tar")"

    update_dockerfile "$version" "$sha_amd64" "$sha_arm64"
    smoke_check_host_binary "$version" "$amd64_tar" "$arm64_tar"

    printf 'updated: %s\n' "$dockerfile"
    printf 'GKE_GCLOUD_AUTH_PLUGIN_VERSION=%s\n' "$version"
    printf 'GKE_GCLOUD_AUTH_PLUGIN_SHA256_AMD64=%s\n' "$sha_amd64"
    printf 'GKE_GCLOUD_AUTH_PLUGIN_SHA256_ARM64=%s\n' "$sha_arm64"
}

main "$@"
