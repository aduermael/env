#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${DOCKERFILE:-${repo_root}/dev.Dockerfile}"
gcloud_rapid_components_url="${GCLOUD_RAPID_COMPONENTS_URL:-https://dl.google.com/dl/cloudsdk/channels/rapid/components-2.json}"
gcloud_cli_base_url="${GCLOUD_CLI_BASE_URL:-https://dl.google.com/dl/cloudsdk/channels/rapid/downloads}"
requested_version="${1:-latest}"
cleanup_tmpdir=""

usage() {
    cat <<'EOF'
Usage: scripts/update-gcloud-cli.sh [latest|VERSION]

Updates the Google Cloud CLI (gcloud) pin in dev.Dockerfile to a rapid-channel
SDK archive (core CLI plus default bundled components).

Examples:
  scripts/update-gcloud-cli.sh
  scripts/update-gcloud-cli.sh 581.0.0

Environment:
  DOCKERFILE                  Path to the Dockerfile to update. Defaults to dev.Dockerfile.
  GCLOUD_RAPID_COMPONENTS_URL Rapid-channel metadata JSON used to resolve latest.
  GCLOUD_CLI_BASE_URL         Base URL for versioned linux SDK archives.
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
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected gcloud CLI version: $version"
}

latest_release_version() {
    local metadata version

    metadata="$(curl -fsSL --retry 3 --retry-delay 2 "$gcloud_rapid_components_url")"
    [[ -n "$metadata" ]] || die "could not fetch rapid-channel metadata from ${gcloud_rapid_components_url}"

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

    [[ -n "$version" && "$version" != "null" ]] || die "could not resolve latest gcloud CLI version from ${gcloud_rapid_components_url}"
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
            die "expected latest or a version like 581.0.0"
            ;;
    esac
}

download_asset() {
    local version="$1"
    local arch="$2"
    local output="$3"
    local asset url sdk_version

    asset="google-cloud-cli-${version}-linux-${arch}.tar.gz"
    url="${gcloud_cli_base_url%/}/${asset}"

    printf 'download: %s\n' "$asset"
    curl -fsSL --retry 3 --retry-delay 2 -o "$output" "$url"
    tar -tzf "$output" google-cloud-sdk/bin/gcloud >/dev/null ||
        die "asset ${asset} does not contain google-cloud-sdk/bin/gcloud"

    sdk_version="$(tar -xOf "$output" google-cloud-sdk/VERSION | head -n 1 | tr -d '[:space:]')"
    [[ "$sdk_version" == "$version" ]] ||
        die "asset ${asset} VERSION is ${sdk_version}, expected ${version}"
}

update_dockerfile() {
    local version="$1"
    local sha_amd64="$2"
    local sha_arm64="$3"
    local tmp

    [[ -f "$dockerfile" ]] || die "Dockerfile not found: $dockerfile"
    tmp="$(mktemp "${TMPDIR:-/tmp}/update-gcloud-cli-dockerfile.XXXXXX")"

    awk \
        -v version="$version" \
        -v sha_amd64="$sha_amd64" \
        -v sha_arm64="$sha_arm64" \
        '
        /^ARG GCLOUD_CLI_VERSION=/ {
            print "ARG GCLOUD_CLI_VERSION=" version
            saw_version = 1
            next
        }
        /^ARG GCLOUD_CLI_SHA256_AMD64=/ {
            print "ARG GCLOUD_CLI_SHA256_AMD64=" sha_amd64
            saw_amd64 = 1
            next
        }
        /^ARG GCLOUD_CLI_SHA256_ARM64=/ {
            print "ARG GCLOUD_CLI_SHA256_ARM64=" sha_arm64
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
            die "could not update gcloud CLI ARGs in $dockerfile"
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
    require_command curl
    require_command mktemp
    require_command sed
    require_command tar

    local version tmpdir amd64_tar arm64_tar sha_amd64 sha_arm64
    version="$(normalize_release_version "$requested_version")"

    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/update-gcloud-cli.XXXXXX")"
    cleanup_tmpdir="$tmpdir"
    trap 'rm -rf "$cleanup_tmpdir"' EXIT

    printf 'release: %s\n' "$version"
    amd64_tar="${tmpdir}/google-cloud-cli-linux-x86_64.tar.gz"
    arm64_tar="${tmpdir}/google-cloud-cli-linux-arm.tar.gz"

    download_asset "$version" "x86_64" "$amd64_tar"
    download_asset "$version" "arm" "$arm64_tar"

    sha_amd64="$(sha256_file "$amd64_tar")"
    sha_arm64="$(sha256_file "$arm64_tar")"

    update_dockerfile "$version" "$sha_amd64" "$sha_arm64"

    printf 'updated: %s\n' "$dockerfile"
    printf 'GCLOUD_CLI_VERSION=%s\n' "$version"
    printf 'GCLOUD_CLI_SHA256_AMD64=%s\n' "$sha_amd64"
    printf 'GCLOUD_CLI_SHA256_ARM64=%s\n' "$sha_arm64"
}

main "$@"
