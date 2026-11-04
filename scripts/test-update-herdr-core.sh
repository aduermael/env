#!/usr/bin/env bash
# Structural + network smoke test for scripts/update-herdr-core.sh.
# Drives the shipped updater against a fixture copy of dev.Dockerfile.
# 1. Corrupt the herdr-core SHA ARGs, pin the shipped HERDR_CORE_VERSION, and
#    assert both SHA ARGs are restored to the manifest digests while the
#    install and version-check lines stay in place.
# 2. Run the updater with no version argument and assert it writes the
#    release named by latest.json, with that release's checksums.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${DOCKERFILE:-${repo_root}/dev.Dockerfile}"
update_script="${repo_root}/scripts/update-herdr-core.sh"
releases_url="${HERDR_CORE_RELEASES_URL:-https://releases.herdr.dev/core}"
tmpdir=""

die() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${tmpdir}" && -d "${tmpdir}" ]]; then
        rm -rf "${tmpdir}"
    fi
}
trap cleanup EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

arg_value() {
    local name="$1"
    local file="${2:-$dockerfile}"
    local line
    line="$(grep -E "^ARG ${name}=" "$file" || true)"
    [[ -n "$line" ]] || die "missing ARG ${name}= in ${file}"
    printf '%s\n' "${line#ARG ${name}=}"
}

normalize_core_args() {
    awk '
        /^ARG HERDR_CORE_VERSION=/ { print "ARG HERDR_CORE_VERSION=<version>"; next }
        /^ARG HERDR_CORE_SHA256_AMD64=/ { print "ARG HERDR_CORE_SHA256_AMD64=<amd64>"; next }
        /^ARG HERDR_CORE_SHA256_ARM64=/ { print "ARG HERDR_CORE_SHA256_ARM64=<arm64>"; next }
        { print }
    ' "$1"
}

assert_install_lines() {
    local file="$1"
    grep -Fq 'herdr_core_file="herdr-core-${herdr_core_target}.tar.gz"' "$file" \
        || die "update-herdr-core.sh rewrite dropped the archive filename line"
    grep -Fq 'https://releases.herdr.dev/core/${HERDR_CORE_VERSION}/${herdr_core_file}' "$file" \
        || die "update-herdr-core.sh rewrite dropped the download URL"
    grep -Fq 'install -m 0755 /tmp/herdr-core/herdr-core /usr/local/bin/herdr-core' "$file" \
        || die "update-herdr-core.sh rewrite dropped the install line"
    grep -Fq 'grep -Fx "hc ${HERDR_CORE_VERSION}"' "$file" \
        || die "update-herdr-core.sh rewrite dropped the version check"
}

manifest_digests() {
    local url="$1"
    local manifest
    manifest="$(curl -fsSL --retry 3 --retry-delay 2 "$url")" || return 1
    HC_MANIFEST="$manifest" python3 - <<'PY'
import json
import os
import sys

data = json.loads(os.environ["HC_MANIFEST"])
targets = data.get("targets") or {}
version = str(data.get("version") or "")
amd64 = str((targets.get("linux-x86_64") or {}).get("sha256") or "").lower()
arm64 = str((targets.get("linux-aarch64") or {}).get("sha256") or "").lower()
if not version or not amd64 or not arm64:
    sys.exit(1)
print(version)
print(amd64)
print(arm64)
PY
}

# Rewrites through a temp file: BSD sed's -i needs a suffix, GNU's does not.
corrupt_shas() {
    sed \
        -e 's/^ARG HERDR_CORE_SHA256_AMD64=.*/ARG HERDR_CORE_SHA256_AMD64=0000000000000000000000000000000000000000000000000000000000000000/' \
        -e 's/^ARG HERDR_CORE_SHA256_ARM64=.*/ARG HERDR_CORE_SHA256_ARM64=1111111111111111111111111111111111111111111111111111111111111111/' \
        "$1" > "$1.tmp"
    mv "$1.tmp" "$1"
}

require_command grep
require_command awk
require_command mktemp
require_command bash
require_command sed
require_command curl
require_command diff
require_command python3

[[ -f "$dockerfile" ]] || die "Dockerfile not found: $dockerfile"
[[ -f "$update_script" ]] || die "update script not found: $update_script"

bash -n "$update_script" || die "bash -n failed for update-herdr-core.sh"

version="$(arg_value HERDR_CORE_VERSION)"
sha_amd64="$(arg_value HERDR_CORE_SHA256_AMD64)"
sha_arm64="$(arg_value HERDR_CORE_SHA256_ARM64)"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "HERDR_CORE_VERSION must be an X.Y.Z release, got: $version"
[[ "$sha_amd64" =~ ^[0-9a-f]{64}$ ]] || die "amd64 SHA must be lowercase hex"
[[ "$sha_arm64" =~ ^[0-9a-f]{64}$ ]] || die "arm64 SHA must be lowercase hex"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/test-update-herdr-core.XXXXXX")"

pinned="$(manifest_digests "${releases_url%/}/${version}/manifest.json")" ||
    die "herdr-core manifest has no checksums for pinned ${version}"
[[ "$(printf '%s\n' "$pinned" | sed -n '2p')" == "$sha_amd64" ]] ||
    die "pinned amd64 SHA does not match the herdr-core manifest"
[[ "$(printf '%s\n' "$pinned" | sed -n '3p')" == "$sha_arm64" ]] ||
    die "pinned arm64 SHA does not match the herdr-core manifest"

fixture_df="${tmpdir}/dev.Dockerfile"
cp "$dockerfile" "$fixture_df"
normalize_core_args "$fixture_df" > "${tmpdir}/before-normalized.txt"
corrupt_shas "$fixture_df"

[[ "$(arg_value HERDR_CORE_SHA256_AMD64 "$fixture_df")" == "0000000000000000000000000000000000000000000000000000000000000000" ]] \
    || die "failed to corrupt fixture amd64 SHA"

DOCKERFILE="$fixture_df" bash "$update_script" "$version"

[[ "$(arg_value HERDR_CORE_VERSION "$fixture_df")" == "$version" ]] \
    || die "update-herdr-core.sh did not keep HERDR_CORE_VERSION=${version}"
[[ "$(arg_value HERDR_CORE_SHA256_AMD64 "$fixture_df")" == "$sha_amd64" ]] \
    || die "update-herdr-core.sh did not restore the amd64 SHA"
[[ "$(arg_value HERDR_CORE_SHA256_ARM64 "$fixture_df")" == "$sha_arm64" ]] \
    || die "update-herdr-core.sh did not restore the arm64 SHA"

assert_install_lines "$fixture_df"
normalize_core_args "$fixture_df" > "${tmpdir}/after-pinned-normalized.txt"
diff -u "${tmpdir}/before-normalized.txt" "${tmpdir}/after-pinned-normalized.txt" \
    || die "pinned update changed lines other than the herdr-core ARGs"

printf 'ok: update-herdr-core.sh restored herdr-core SHA ARGs for %s\n' "$version"

# No version argument: the release named by latest.json.
fixture_latest="${tmpdir}/dev.Dockerfile.latest"
cp "$dockerfile" "$fixture_latest"
corrupt_shas "$fixture_latest"

DOCKERFILE="$fixture_latest" bash "$update_script"

latest="$(manifest_digests "${releases_url%/}/latest.json")" ||
    die "could not read the newest herdr-core release from latest.json"
expected_latest="$(printf '%s\n' "$latest" | sed -n '1p')"
expected_latest_amd64="$(printf '%s\n' "$latest" | sed -n '2p')"
expected_latest_arm64="$(printf '%s\n' "$latest" | sed -n '3p')"

latest_version="$(arg_value HERDR_CORE_VERSION "$fixture_latest")"
[[ "$latest_version" == "$expected_latest" ]] ||
    die "updater without a version pinned ${latest_version}, latest.json names ${expected_latest}"
[[ "$(arg_value HERDR_CORE_SHA256_AMD64 "$fixture_latest")" == "$expected_latest_amd64" ]] ||
    die "latest amd64 SHA does not match latest.json"
[[ "$(arg_value HERDR_CORE_SHA256_ARM64 "$fixture_latest")" == "$expected_latest_arm64" ]] ||
    die "latest arm64 SHA does not match latest.json"

assert_install_lines "$fixture_latest"
normalize_core_args "$fixture_latest" > "${tmpdir}/after-latest-normalized.txt"
diff -u "${tmpdir}/before-normalized.txt" "${tmpdir}/after-latest-normalized.txt" \
    || die "latest update changed lines other than the herdr-core ARGs"

printf 'ok: update-herdr-core.sh with no version pinned %s\n' "$latest_version"
printf 'ALL CHECKS PASSED\n'
