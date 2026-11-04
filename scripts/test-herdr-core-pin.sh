#!/usr/bin/env bash
# Structural + network smoke test for the herdr-core (hc) pin.
# Reads the shipped dev.Dockerfile (not a copy) and asserts a concrete
# herdr-core release is installed, that its digests match the release
# manifest and the archives, and that the image build itself runs
# `hc --version` against that pin.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${DOCKERFILE:-${repo_root}/dev.Dockerfile}"
releases_url="${HERDR_CORE_RELEASES_URL:-https://releases.herdr.dev/core}"

die() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

sha256_stream() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    else
        die "required command not found: sha256sum or shasum"
    fi
}

arg_value() {
    local name="$1"
    local line
    line="$(grep -E "^ARG ${name}=" "$dockerfile" || true)"
    [[ -n "$line" ]] || die "missing ARG ${name}= in ${dockerfile}"
    printf '%s\n' "${line#ARG ${name}=}"
}

require_command curl
require_command grep
require_command awk
require_command python3

[[ -f "$dockerfile" ]] || die "Dockerfile not found: $dockerfile"

version="$(arg_value HERDR_CORE_VERSION)"
sha_amd64="$(arg_value HERDR_CORE_SHA256_AMD64)"
sha_arm64="$(arg_value HERDR_CORE_SHA256_ARM64)"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "HERDR_CORE_VERSION must be an X.Y.Z release, got: $version"
[[ "$sha_amd64" =~ ^[0-9a-f]{64}$ ]] || die "amd64 SHA must be 64 lowercase hex chars"
[[ "$sha_arm64" =~ ^[0-9a-f]{64}$ ]] || die "arm64 SHA must be 64 lowercase hex chars"

grep -Fq 'amd64|x86_64) herdr_core_target="linux-x86_64"; herdr_core_sha256="${HERDR_CORE_SHA256_AMD64}"' "$dockerfile" \
    || die "Dockerfile does not map amd64 to herdr-core-linux-x86_64"
grep -Fq 'arm64|aarch64) herdr_core_target="linux-aarch64"; herdr_core_sha256="${HERDR_CORE_SHA256_ARM64}"' "$dockerfile" \
    || die "Dockerfile does not map arm64 to herdr-core-linux-aarch64"
grep -Fq 'herdr_core_file="herdr-core-${herdr_core_target}.tar.gz"' "$dockerfile" \
    || die "Dockerfile does not download herdr-core-\${herdr_core_target}.tar.gz"
grep -Fq 'https://releases.herdr.dev/core/${HERDR_CORE_VERSION}/${herdr_core_file}' "$dockerfile" \
    || die "Dockerfile does not fetch herdr-core from releases.herdr.dev/core"
grep -Fq 'install -m 0755 /tmp/herdr-core/herdr-core /usr/local/bin/herdr-core' "$dockerfile" \
    || die "Dockerfile does not install /usr/local/bin/herdr-core"
grep -Fq 'ln -sfn herdr-core /usr/local/bin/hc' "$dockerfile" \
    || die "Dockerfile does not create the /usr/local/bin/hc symlink"
grep -Fq 'test "$(command -v hc)" = "/usr/local/bin/hc"' "$dockerfile" \
    || die "Dockerfile does not install hc onto PATH"
grep -Fq 'hc --version' "$dockerfile" \
    || die "Dockerfile does not invoke hc --version during the image build"
grep -Fq 'grep -Fx "hc ${HERDR_CORE_VERSION}"' "$dockerfile" \
    || die "Dockerfile does not check hc version against the pinned release"

# The versioned manifest is the source of truth for the digests.
manifest="$(curl -fsSL --retry 3 --retry-delay 2 "${releases_url%/}/${version}/manifest.json")"
[[ -n "$manifest" ]] || die "could not download the herdr-core manifest for ${version}"
manifest_digests="$(HC_MANIFEST="$manifest" python3 - <<'PY'
import json
import os
import sys

data = json.loads(os.environ["HC_MANIFEST"])
targets = data.get("targets") or {}
print(str(data.get("version") or ""))
for target in ("linux-x86_64", "linux-aarch64"):
    print(str((targets.get(target) or {}).get("sha256") or "").lower())
PY
)"
[[ "$(printf '%s\n' "$manifest_digests" | sed -n '1p')" == "$version" ]] \
    || die "manifest version does not match HERDR_CORE_VERSION=${version}"
[[ "$(printf '%s\n' "$manifest_digests" | sed -n '2p')" == "$sha_amd64" ]] \
    || die "pinned amd64 SHA does not match the herdr-core manifest"
[[ "$(printf '%s\n' "$manifest_digests" | sed -n '3p')" == "$sha_arm64" ]] \
    || die "pinned arm64 SHA does not match the herdr-core manifest"
printf 'ok: manifest digests match for %s\n' "$version"

# Live checksums for the pinned archives (the files the Dockerfile fetches).
verify_archive() {
    local target="$1"
    local expected_sha="$2"
    local file="herdr-core-${target}.tar.gz"
    local url="${releases_url%/}/${version}/${file}"
    local actual

    printf 'download: %s\n' "$file"
    actual="$(curl -fsSL --retry 3 --retry-delay 2 "$url" | sha256_stream)"
    [[ "$actual" == "$expected_sha" ]] || die "${file}: digest mismatch (expected ${expected_sha}, got ${actual})"
    printf 'ok: %s digest match\n' "$file"
}

verify_archive "linux-x86_64" "$sha_amd64"
verify_archive "linux-aarch64" "$sha_arm64"

printf 'ok: herdr-core %s is pinned with in-build version check\n' "$version"
printf 'ALL CHECKS PASSED\n'
