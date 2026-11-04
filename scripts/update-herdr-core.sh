#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${DOCKERFILE:-${repo_root}/dev.Dockerfile}"
herdr_core_releases_url="${HERDR_CORE_RELEASES_URL:-https://releases.herdr.dev/core}"
requested_version="${1:-latest}"
cleanup_tmpdir=""

usage() {
    cat <<'EOF'
Usage: scripts/update-herdr-core.sh [latest|VERSION]

Updates the herdr-core (hc) pin in dev.Dockerfile.
Without a version, tracks the newest release published at releases.herdr.dev.

Examples:
  scripts/update-herdr-core.sh
  scripts/update-herdr-core.sh 0.1.17
  scripts/update-herdr-core.sh v0.1.17

Environment:
  DOCKERFILE                 Path to the Dockerfile to update. Defaults to dev.Dockerfile.
  HERDR_CORE_RELEASES_URL    Base URL of the herdr-core releases. Defaults to
                             https://releases.herdr.dev/core. latest.json names the newest
                             release; <version>/manifest.json names one release. Both carry
                             the archive URL and SHA-256 for every target.
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

manifest_url_for() {
    local requested="$1"
    local version="$requested"
    if [[ "$version" == "latest" || -z "$version" ]]; then
        printf '%s/latest.json\n' "${herdr_core_releases_url%/}"
        return 0
    fi
    version="${version#v}"
    printf '%s/%s/manifest.json\n' "${herdr_core_releases_url%/}" "$version"
}

resolve_manifest() {
    local manifest="$1"
    local requested="$2"

    HC_MANIFEST="$manifest" HC_REQUESTED="$requested" HC_RELEASES="${herdr_core_releases_url%/}" python3 - <<'PY'
import json
import os
import re
import sys

stable = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
hex64 = re.compile(r"^[0-9a-f]{64}$")

with open(os.environ["HC_MANIFEST"], encoding="utf-8") as handle:
    data = json.load(handle)

requested = os.environ.get("HC_REQUESTED") or "latest"
version = str(data.get("version") or "")
if requested not in ("latest", ""):
    wanted = requested[1:] if requested.startswith("v") else requested
    if version != wanted:
        sys.stderr.write("herdr-core manifest names %s, expected %s\n" % (version, wanted))
        sys.exit(1)

if not stable.fullmatch(version):
    sys.stderr.write("unexpected herdr-core version: %s\n" % version)
    sys.exit(1)

targets = data.get("targets") or {}
out = [version]
for target in ("linux-x86_64", "linux-aarch64"):
    entry = targets.get(target) or {}
    digest = str(entry.get("sha256") or "").lower()
    url = str(entry.get("url") or "")
    if not hex64.fullmatch(digest):
        sys.stderr.write("herdr-core manifest is missing the %s checksum for %s\n" % (target, version))
        sys.exit(1)
    suffix = "/%s/herdr-core-%s.tar.gz" % (version, target)
    if not url.endswith(suffix):
        sys.stderr.write("herdr-core manifest asset %s is %s, expected suffix %s\n" % (target, url, suffix))
        sys.exit(1)
    out.append(digest)

print("\n".join(out))
PY
}

download_asset() {
    local version="$1"
    local target="$2"
    local output="$3"
    local expected="$4"
    local asset url actual

    asset="herdr-core-${target}.tar.gz"
    url="${herdr_core_releases_url%/}/${version}/${asset}"

    printf 'download: %s\n' "$asset"
    curl -fsSL --retry 3 --retry-delay 2 -o "$output" "$url"
    [[ -s "$output" ]] || die "downloaded asset is empty: ${asset}"
    python3 -c 'import sys; data=open(sys.argv[1], "rb").read(2); sys.exit(0 if data == b"\x1f\x8b" else 1)' "$output" ||
        die "asset ${asset} is not a gzip archive"

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
    tmp="$(mktemp "${TMPDIR:-/tmp}/update-herdr-core-dockerfile.XXXXXX")"

    awk \
        -v version="$version" \
        -v sha_amd64="$sha_amd64" \
        -v sha_arm64="$sha_arm64" \
        '
        /^ARG HERDR_CORE_VERSION=/ {
            print "ARG HERDR_CORE_VERSION=" version
            saw_version = 1
            next
        }
        /^ARG HERDR_CORE_SHA256_AMD64=/ {
            print "ARG HERDR_CORE_SHA256_AMD64=" sha_amd64
            saw_amd64 = 1
            next
        }
        /^ARG HERDR_CORE_SHA256_ARM64=/ {
            print "ARG HERDR_CORE_SHA256_ARM64=" sha_arm64
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
            die "could not update herdr-core ARGs in $dockerfile"
        }

    cp "$tmp" "$dockerfile"
    rm -f "$tmp"
}

smoke_check_host_binary() {
    local version="$1"
    local amd64_archive="$2"
    local arm64_archive="$3"
    local tmpdir="$4"
    local kernel arch target archive out

    kernel="$(uname -s)"
    arch="$(uname -m)"

    case "${kernel}/${arch}" in
        Linux/x86_64|Linux/amd64)
            target="amd64"
            archive="$amd64_archive"
            ;;
        Linux/aarch64|Linux/arm64)
            target="arm64"
            archive="$arm64_archive"
            ;;
        *)
            printf 'skip: host binary smoke check is only run on Linux amd64/arm64\n'
            return 0
            ;;
    esac

    mkdir -p "${tmpdir}/extract"
    tar -xzf "$archive" -C "${tmpdir}/extract" herdr-core
    chmod +x "${tmpdir}/extract/herdr-core"
    out="$("${tmpdir}/extract/herdr-core" --version 2>&1)"
    printf '%s\n' "$out" | grep -Fx "hc ${version}" ||
        die "unexpected herdr-core version output: ${out}"
    printf 'ok: herdr-core-%s version -> %s\n' "$target" "$(printf '%s\n' "$out" | head -n 1)"
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
    require_command tar

    local tmpdir manifest manifest_url version sha_amd64 sha_arm64 resolved
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/update-herdr-core.XXXXXX")"
    cleanup_tmpdir="$tmpdir"
    trap 'rm -rf "$cleanup_tmpdir"' EXIT

    manifest_url="$(manifest_url_for "$requested_version")"
    manifest="${tmpdir}/manifest.json"
    curl -fsSL --retry 3 --retry-delay 2 -o "$manifest" "$manifest_url"
    [[ -s "$manifest" ]] || die "downloaded herdr-core manifest is empty"

    resolved="$(resolve_manifest "$manifest" "$requested_version")" ||
        die "could not resolve herdr-core release ${requested_version} from ${manifest_url}"
    version="$(printf '%s\n' "$resolved" | sed -n '1p')"
    sha_amd64="$(printf '%s\n' "$resolved" | sed -n '2p')"
    sha_arm64="$(printf '%s\n' "$resolved" | sed -n '3p')"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected herdr-core version: ${version}"
    [[ "$sha_amd64" =~ ^[0-9a-f]{64}$ ]] || die "unexpected amd64 checksum: ${sha_amd64}"
    [[ "$sha_arm64" =~ ^[0-9a-f]{64}$ ]] || die "unexpected arm64 checksum: ${sha_arm64}"

    printf 'release: %s\n' "$version"
    local amd64_archive="${tmpdir}/herdr-core-linux-x86_64.tar.gz"
    local arm64_archive="${tmpdir}/herdr-core-linux-aarch64.tar.gz"
    download_asset "$version" "linux-x86_64" "$amd64_archive" "$sha_amd64"
    download_asset "$version" "linux-aarch64" "$arm64_archive" "$sha_arm64"

    update_dockerfile "$version" "$sha_amd64" "$sha_arm64"
    smoke_check_host_binary "$version" "$amd64_archive" "$arm64_archive" "$tmpdir"

    printf 'updated: %s\n' "$dockerfile"
    printf 'HERDR_CORE_VERSION=%s\n' "$version"
    printf 'HERDR_CORE_SHA256_AMD64=%s\n' "$sha_amd64"
    printf 'HERDR_CORE_SHA256_ARM64=%s\n' "$sha_arm64"
}

main "$@"
