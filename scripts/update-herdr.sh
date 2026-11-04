#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${DOCKERFILE:-${repo_root}/dev.Dockerfile}"
herdr_manifest_url="${HERDR_MANIFEST_URL:-https://herdr.dev/latest.json}"
herdr_release_base_url="${HERDR_RELEASE_BASE_URL:-https://github.com/herdrdev/herdr/releases/download}"
requested_version="${1:-latest}"
cleanup_tmpdir=""

usage() {
    cat <<'EOF'
Usage: scripts/update-herdr.sh [latest|VERSION]

Updates the herdr pin in dev.Dockerfile.
Without a version, tracks the newest stable release published at herdr.dev.

Examples:
  scripts/update-herdr.sh
  scripts/update-herdr.sh 0.9.5
  scripts/update-herdr.sh v0.9.5

Environment:
  DOCKERFILE                 Path to the Dockerfile to update. Defaults to dev.Dockerfile.
  HERDR_MANIFEST_URL         herdr release manifest. Defaults to https://herdr.dev/latest.json.
                             The manifest names the newest stable version and the SHA-256
                             for each published release.
  HERDR_RELEASE_BASE_URL     Base URL for versioned herdr binaries.
                             Defaults to https://github.com/herdrdev/herdr/releases/download.
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

resolve_manifest() {
    local manifest="$1"
    local requested="$2"

    HERDR_MANIFEST="$manifest" HERDR_REQUESTED="$requested" python3 - <<'PY'
import json
import os
import re
import sys

stable = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
hex64 = re.compile(r"^[0-9a-f]{64}$")

with open(os.environ["HERDR_MANIFEST"], encoding="utf-8") as handle:
    data = json.load(handle)

requested = os.environ.get("HERDR_REQUESTED") or "latest"
if requested in ("latest", ""):
    version = str(data.get("version") or "")
elif requested.startswith("v"):
    version = requested[1:]
else:
    version = requested

if not stable.fullmatch(version):
    sys.stderr.write("unexpected herdr version: %s\n" % version)
    sys.exit(1)

releases = data.get("releases") or {}
release = releases.get(version)
if not isinstance(release, dict):
    sys.stderr.write("herdr manifest has no release %s\n" % version)
    sys.exit(1)

checksums = release.get("sha256") or {}
assets = release.get("assets") or {}
amd64 = str(checksums.get("linux-x86_64") or "").lower()
arm64 = str(checksums.get("linux-aarch64") or "").lower()
if not hex64.fullmatch(amd64) or not hex64.fullmatch(arm64):
    sys.stderr.write("herdr manifest is missing linux checksums for %s\n" % version)
    sys.exit(1)

for target, name in (
    ("linux-x86_64", "herdr-linux-x86_64"),
    ("linux-aarch64", "herdr-linux-aarch64"),
):
    url = str(assets.get(target) or "")
    suffix = "/v%s/%s" % (version, name)
    if not url.endswith(suffix):
        sys.stderr.write("herdr manifest asset %s is %s, expected suffix %s\n" % (target, url, suffix))
        sys.exit(1)

print(version)
print(amd64)
print(arm64)
PY
}

download_asset() {
    local version="$1"
    local target="$2"
    local output="$3"
    local expected="$4"
    local asset url actual

    asset="herdr-${target}"
    url="${herdr_release_base_url%/}/v${version}/${asset}"

    printf 'download: %s\n' "$asset"
    curl -fsSL --retry 3 --retry-delay 2 -o "$output" "$url"
    [[ -s "$output" ]] || die "downloaded asset is empty: ${asset}"
    python3 -c 'import sys; data=open(sys.argv[1], "rb").read(4); sys.exit(0 if data == b"\x7fELF" else 1)' "$output" ||
        die "asset ${asset} is not an ELF binary"

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
    tmp="$(mktemp "${TMPDIR:-/tmp}/update-herdr-dockerfile.XXXXXX")"

    awk \
        -v version="$version" \
        -v sha_amd64="$sha_amd64" \
        -v sha_arm64="$sha_arm64" \
        '
        /^ARG HERDR_VERSION=/ {
            print "ARG HERDR_VERSION=" version
            saw_version = 1
            next
        }
        /^ARG HERDR_SHA256_AMD64=/ {
            print "ARG HERDR_SHA256_AMD64=" sha_amd64
            saw_amd64 = 1
            next
        }
        /^ARG HERDR_SHA256_ARM64=/ {
            print "ARG HERDR_SHA256_ARM64=" sha_arm64
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
            die "could not update herdr ARGs in $dockerfile"
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

    chmod +x "$binary"
    out="$("$binary" --version 2>&1)"
    printf '%s\n' "$out" | grep -Fx "herdr ${version}" ||
        die "unexpected herdr version output: ${out}"
    printf 'ok: herdr-%s version -> %s\n' "$target" "$(printf '%s\n' "$out" | head -n 1)"
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

    local tmpdir manifest version sha_amd64 sha_arm64 resolved
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/update-herdr.XXXXXX")"
    cleanup_tmpdir="$tmpdir"
    trap 'rm -rf "$cleanup_tmpdir"' EXIT

    manifest="${tmpdir}/latest.json"
    curl -fsSL --retry 3 --retry-delay 2 -o "$manifest" "$herdr_manifest_url"
    [[ -s "$manifest" ]] || die "downloaded herdr manifest is empty"

    resolved="$(resolve_manifest "$manifest" "$requested_version")" ||
        die "could not resolve herdr release ${requested_version} from ${herdr_manifest_url}"
    version="$(printf '%s\n' "$resolved" | sed -n '1p')"
    sha_amd64="$(printf '%s\n' "$resolved" | sed -n '2p')"
    sha_arm64="$(printf '%s\n' "$resolved" | sed -n '3p')"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected herdr version: ${version}"
    [[ "$sha_amd64" =~ ^[0-9a-f]{64}$ ]] || die "unexpected amd64 checksum: ${sha_amd64}"
    [[ "$sha_arm64" =~ ^[0-9a-f]{64}$ ]] || die "unexpected arm64 checksum: ${sha_arm64}"

    printf 'release: %s\n' "$version"
    local amd64_bin="${tmpdir}/herdr-linux-x86_64"
    local arm64_bin="${tmpdir}/herdr-linux-aarch64"
    download_asset "$version" "linux-x86_64" "$amd64_bin" "$sha_amd64"
    download_asset "$version" "linux-aarch64" "$arm64_bin" "$sha_arm64"

    update_dockerfile "$version" "$sha_amd64" "$sha_arm64"
    smoke_check_host_binary "$version" "$amd64_bin" "$arm64_bin"

    printf 'updated: %s\n' "$dockerfile"
    printf 'HERDR_VERSION=%s\n' "$version"
    printf 'HERDR_SHA256_AMD64=%s\n' "$sha_amd64"
    printf 'HERDR_SHA256_ARM64=%s\n' "$sha_arm64"
}

main "$@"
