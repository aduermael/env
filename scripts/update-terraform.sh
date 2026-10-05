#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${DOCKERFILE:-${repo_root}/dev.Dockerfile}"
terraform_releases_base_url="${TERRAFORM_RELEASES_BASE_URL:-https://releases.hashicorp.com/terraform}"
terraform_releases_api="${TERRAFORM_RELEASES_API:-https://api.releases.hashicorp.com}"
requested_version="${1:-latest}"
cleanup_tmpdir=""

usage() {
    cat <<'EOF'
Usage: scripts/update-terraform.sh [latest|VERSION]

Updates the Terraform pin in dev.Dockerfile.
Without a version, tracks the newest stable HashiCorp release
(prereleases such as alpha, beta, and rc are skipped).

Examples:
  scripts/update-terraform.sh
  scripts/update-terraform.sh 1.16.5
  scripts/update-terraform.sh v1.16.5

Environment:
  DOCKERFILE                    Path to the Dockerfile to update. Defaults to dev.Dockerfile.
  TERRAFORM_RELEASES_BASE_URL   Base URL for Terraform release zips and SHA256SUMS.
                                Defaults to https://releases.hashicorp.com/terraform.
  TERRAFORM_RELEASES_API        HashiCorp releases API used to resolve the newest stable version.
                                Defaults to https://api.releases.hashicorp.com.
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
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die "unexpected Terraform version: $version"
}

validate_stable_version() {
    local version="$1"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected stable Terraform version: $version"
}

latest_release_version() {
    local latest_payload list_payload version

    # /latest is HashiCorp's stable channel. The recent-release page is checked
    # too, and any prerelease (alpha, beta, rc) is dropped before the highest
    # X.Y.Z is chosen. The API rejects limit values above 20.
    latest_payload="$(curl -fsSL --retry 3 --retry-delay 2 "${terraform_releases_api%/}/v1/releases/terraform/latest")"
    list_payload="$(curl -fsSL --retry 3 --retry-delay 2 "${terraform_releases_api%/}/v1/releases/terraform?limit=20")"
    version="$(
        TERRAFORM_LATEST_JSON="$latest_payload" TERRAFORM_LIST_JSON="$list_payload" python3 -c '
import json
import os
import re
import sys

stable = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")

def consider(rel, found):
    if not isinstance(rel, dict) or rel.get("is_prerelease") is True:
        return
    version = str(rel.get("version") or "")
    if not stable.fullmatch(version):
        return
    parts = tuple(int(part) for part in version.split("."))
    if found[0] is None or parts > found[0][0]:
        found[0] = (parts, version)

latest = json.loads(os.environ["TERRAFORM_LATEST_JSON"])
raw = json.loads(os.environ["TERRAFORM_LIST_JSON"])
if isinstance(raw, dict):
    releases = raw.get("releases") or raw.get("data") or []
else:
    releases = raw

found = [None]
consider(latest, found)
for rel in releases:
    consider(rel, found)
if found[0] is None:
    sys.exit(1)
print(found[0][1])
'
    )" || die "could not resolve newest stable Terraform release from ${terraform_releases_api%/}/v1/releases/terraform"
    validate_stable_version "$version"
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
        die "SHA256SUMS does not list ${asset}"
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "unexpected official checksum for ${asset}: ${expected}"
    printf '%s\n' "$expected"
}

download_asset() {
    local version="$1"
    local arch="$2"
    local output="$3"
    local checksums_file="$4"
    local asset url expected actual

    asset="terraform_${version}_linux_${arch}.zip"
    url="${terraform_releases_base_url%/}/${version}/${asset}"

    printf 'download: %s\n' "$asset"
    curl -fsSL --retry 3 --retry-delay 2 -o "$output" "$url"
    [[ -s "$output" ]] || die "downloaded asset is empty: ${asset}"

    expected="$(official_checksum "$checksums_file" "$asset")"
    actual="$(sha256_file "$output")"
    [[ "$actual" == "$expected" ]] ||
        die "${asset} digest mismatch (official ${expected}, got ${actual})"

    python3 -c '
import sys
import zipfile
path = sys.argv[1]
try:
    names = zipfile.ZipFile(path).namelist()
except zipfile.BadZipFile as exc:
    sys.stderr.write("bad zip: %s\n" % exc)
    sys.exit(1)
if "terraform" not in names:
    sys.stderr.write("names: %s\n" % ", ".join(names))
    sys.exit(1)
' "$output" || die "asset ${asset} does not contain terraform"
}

update_dockerfile() {
    local version="$1"
    local sha_amd64="$2"
    local sha_arm64="$3"
    local tmp

    [[ -f "$dockerfile" ]] || die "Dockerfile not found: $dockerfile"
    tmp="$(mktemp "${TMPDIR:-/tmp}/update-terraform-dockerfile.XXXXXX")"

    awk \
        -v version="$version" \
        -v sha_amd64="$sha_amd64" \
        -v sha_arm64="$sha_arm64" \
        '
        /^ARG TERRAFORM_VERSION=/ {
            print "ARG TERRAFORM_VERSION=" version
            saw_version = 1
            next
        }
        /^ARG TERRAFORM_SHA256_AMD64=/ {
            print "ARG TERRAFORM_SHA256_AMD64=" sha_amd64
            saw_amd64 = 1
            next
        }
        /^ARG TERRAFORM_SHA256_ARM64=/ {
            print "ARG TERRAFORM_SHA256_ARM64=" sha_arm64
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
            die "could not update Terraform ARGs in $dockerfile"
        }

    cp "$tmp" "$dockerfile"
    rm -f "$tmp"
}

smoke_check_host_binary() {
    local version="$1"
    local tmpdir="$2"
    local amd64_zip="$3"
    local arm64_zip="$4"
    local kernel arch target archive smoke_dir out

    kernel="$(uname -s)"
    arch="$(uname -m)"

    case "${kernel}/${arch}" in
        Linux/x86_64|Linux/amd64)
            target="amd64"
            archive="$amd64_zip"
            ;;
        Linux/aarch64|Linux/arm64)
            target="arm64"
            archive="$arm64_zip"
            ;;
        *)
            printf 'skip: host binary smoke check is only run on Linux amd64/arm64\n'
            return 0
            ;;
    esac

    smoke_dir="${tmpdir}/smoke"
    mkdir -p "$smoke_dir"
    unzip -oq "$archive" -d "$smoke_dir"
    out="$(CHECKPOINT_DISABLE=1 "${smoke_dir}/terraform" version)"
    printf '%s\n' "$out" | grep -Fq "Terraform v${version}" ||
        die "unexpected Terraform version output: ${out}"
    printf 'ok: terraform-%s version -> %s\n' "$target" "$(printf '%s\n' "$out" | head -n 1)"
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
    require_command python3
    require_command unzip

    local version tmpdir checksums_file amd64_zip arm64_zip sha_amd64 sha_arm64
    version="$(normalize_release_version "$requested_version")"

    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/update-terraform.XXXXXX")"
    cleanup_tmpdir="$tmpdir"
    trap 'rm -rf "$cleanup_tmpdir"' EXIT

    printf 'release: %s\n' "$version"
    checksums_file="${tmpdir}/terraform_${version}_SHA256SUMS"
    curl -fsSL --retry 3 --retry-delay 2 -o "$checksums_file" \
        "${terraform_releases_base_url%/}/${version}/terraform_${version}_SHA256SUMS"
    [[ -s "$checksums_file" ]] || die "downloaded SHA256SUMS is empty for Terraform ${version}"

    amd64_zip="${tmpdir}/terraform-linux-amd64.zip"
    arm64_zip="${tmpdir}/terraform-linux-arm64.zip"

    download_asset "$version" "amd64" "$amd64_zip" "$checksums_file"
    download_asset "$version" "arm64" "$arm64_zip" "$checksums_file"

    sha_amd64="$(sha256_file "$amd64_zip")"
    sha_arm64="$(sha256_file "$arm64_zip")"

    update_dockerfile "$version" "$sha_amd64" "$sha_arm64"
    smoke_check_host_binary "$version" "$tmpdir" "$amd64_zip" "$arm64_zip"

    printf 'updated: %s\n' "$dockerfile"
    printf 'TERRAFORM_VERSION=%s\n' "$version"
    printf 'TERRAFORM_SHA256_AMD64=%s\n' "$sha_amd64"
    printf 'TERRAFORM_SHA256_ARM64=%s\n' "$sha_arm64"
}

main "$@"
