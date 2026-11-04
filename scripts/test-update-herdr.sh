#!/usr/bin/env bash
# Structural + network smoke test for scripts/update-herdr.sh.
# Drives the shipped updater against a fixture copy of dev.Dockerfile.
# 1. Corrupt the herdr SHA ARGs, pin the shipped HERDR_VERSION, and assert
#    both SHA ARGs are restored to the live release digests while the install
#    and version-check lines stay in place.
# 2. Run the updater with no version argument and assert it writes the stable
#    release named by the herdr.dev manifest, with that release's checksums.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${DOCKERFILE:-${repo_root}/dev.Dockerfile}"
update_script="${repo_root}/scripts/update-herdr.sh"
pr_runner="${repo_root}/.codex/skills/update-software/scripts/update-software-pr.sh"
manifest_url="${HERDR_MANIFEST_URL:-https://herdr.dev/latest.json}"
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

normalize_non_herdr_args() {
    awk '
        /^ARG HERDR_VERSION=/ { print "ARG HERDR_VERSION=<version>"; next }
        /^ARG HERDR_SHA256_AMD64=/ { print "ARG HERDR_SHA256_AMD64=<amd64>"; next }
        /^ARG HERDR_SHA256_ARM64=/ { print "ARG HERDR_SHA256_ARM64=<arm64>"; next }
        { print }
    ' "$1"
}

assert_install_lines() {
    local file="$1"
    grep -Fq 'herdr_file="herdr-${herdr_target}"' "$file" \
        || die "update-herdr.sh rewrite dropped herdr archive filename line"
    grep -Fq 'https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/${herdr_file}' "$file" \
        || die "update-herdr.sh rewrite dropped herdr download URL"
    grep -Fq 'install -m 0755 "/tmp/${herdr_file}" /usr/local/bin/herdr' "$file" \
        || die "update-herdr.sh rewrite dropped herdr install line"
    grep -Fq 'grep -Fx "herdr ${HERDR_VERSION}"' "$file" \
        || die "update-herdr.sh rewrite dropped herdr version check"
}

manifest_release() {
    local manifest="$1"
    local version="$2"
    HERDR_MANIFEST="$manifest" HERDR_VERSION_QUERY="$version" python3 - <<'PY'
import json
import os
import sys

with open(os.environ["HERDR_MANIFEST"], encoding="utf-8") as handle:
    data = json.load(handle)

version = os.environ["HERDR_VERSION_QUERY"]
if version == "latest":
    version = str(data.get("version") or "")
release = (data.get("releases") or {}).get(version) or {}
checksums = release.get("sha256") or {}
amd64 = str(checksums.get("linux-x86_64") or "")
arm64 = str(checksums.get("linux-aarch64") or "")
if not version or not amd64 or not arm64:
    sys.exit(1)
print(version)
print(amd64.lower())
print(arm64.lower())
PY
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
[[ -f "$pr_runner" ]] || die "PR runner not found: $pr_runner"

bash -n "$update_script" || die "bash -n failed for update-herdr.sh"
bash -n "$pr_runner" || die "bash -n failed for update-software-pr.sh"

version="$(arg_value HERDR_VERSION)"
sha_amd64="$(arg_value HERDR_SHA256_AMD64)"
sha_arm64="$(arg_value HERDR_SHA256_ARM64)"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "HERDR_VERSION must be a stable X.Y.Z release, got: $version"
[[ "$sha_amd64" =~ ^[0-9a-f]{64}$ ]] || die "amd64 SHA must be lowercase hex"
[[ "$sha_arm64" =~ ^[0-9a-f]{64}$ ]] || die "arm64 SHA must be lowercase hex"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/test-update-herdr.XXXXXX")"
manifest="${tmpdir}/latest.json"
curl -fsSL --retry 3 --retry-delay 2 -o "$manifest" "$manifest_url"
[[ -s "$manifest" ]] || die "downloaded herdr manifest is empty"

manifest_pinned="$(manifest_release "$manifest" "$version")" ||
    die "herdr manifest has no checksums for pinned ${version}"
[[ "$(printf '%s\n' "$manifest_pinned" | sed -n '2p')" == "$sha_amd64" ]] ||
    die "pinned amd64 SHA does not match the herdr manifest"
[[ "$(printf '%s\n' "$manifest_pinned" | sed -n '3p')" == "$sha_arm64" ]] ||
    die "pinned arm64 SHA does not match the herdr manifest"

fixture_df="${tmpdir}/dev.Dockerfile"
cp "$dockerfile" "$fixture_df"
normalize_non_herdr_args "$fixture_df" > "${tmpdir}/before-normalized.txt"

sed -i \
    -e 's/^ARG HERDR_SHA256_AMD64=.*/ARG HERDR_SHA256_AMD64=0000000000000000000000000000000000000000000000000000000000000000/' \
    -e 's/^ARG HERDR_SHA256_ARM64=.*/ARG HERDR_SHA256_ARM64=1111111111111111111111111111111111111111111111111111111111111111/' \
    "$fixture_df"

[[ "$(arg_value HERDR_SHA256_AMD64 "$fixture_df")" == "0000000000000000000000000000000000000000000000000000000000000000" ]] \
    || die "failed to corrupt fixture amd64 SHA"
[[ "$(arg_value HERDR_SHA256_ARM64 "$fixture_df")" == "1111111111111111111111111111111111111111111111111111111111111111" ]] \
    || die "failed to corrupt fixture arm64 SHA"

DOCKERFILE="$fixture_df" bash "$update_script" "$version"

rewritten_version="$(arg_value HERDR_VERSION "$fixture_df")"
rewritten_amd64="$(arg_value HERDR_SHA256_AMD64 "$fixture_df")"
rewritten_arm64="$(arg_value HERDR_SHA256_ARM64 "$fixture_df")"

[[ "$rewritten_version" == "$version" ]] || die "update-herdr.sh did not keep HERDR_VERSION=${version} (got ${rewritten_version})"
[[ "$rewritten_amd64" == "$sha_amd64" ]] || die "update-herdr.sh did not restore amd64 SHA (got ${rewritten_amd64})"
[[ "$rewritten_arm64" == "$sha_arm64" ]] || die "update-herdr.sh did not restore arm64 SHA (got ${rewritten_arm64})"

assert_install_lines "$fixture_df"
normalize_non_herdr_args "$fixture_df" > "${tmpdir}/after-pinned-normalized.txt"
diff -u "${tmpdir}/before-normalized.txt" "${tmpdir}/after-pinned-normalized.txt" \
    || die "pinned update changed lines other than the herdr ARGs"

printf 'ok: update-herdr.sh restored herdr SHA ARGs for %s\n' "$version"

# No version argument: newest stable release named by the herdr.dev manifest.
fixture_latest="${tmpdir}/dev.Dockerfile.latest"
cp "$dockerfile" "$fixture_latest"
sed -i \
    -e 's/^ARG HERDR_SHA256_AMD64=.*/ARG HERDR_SHA256_AMD64=0000000000000000000000000000000000000000000000000000000000000000/' \
    -e 's/^ARG HERDR_SHA256_ARM64=.*/ARG HERDR_SHA256_ARM64=1111111111111111111111111111111111111111111111111111111111111111/' \
    "$fixture_latest"

DOCKERFILE="$fixture_latest" bash "$update_script"

latest_version="$(arg_value HERDR_VERSION "$fixture_latest")"
latest_amd64="$(arg_value HERDR_SHA256_AMD64 "$fixture_latest")"
latest_arm64="$(arg_value HERDR_SHA256_ARM64 "$fixture_latest")"

manifest_latest="$(manifest_release "$manifest" "latest")" ||
    die "could not read the newest herdr release from the manifest"
expected_latest="$(printf '%s\n' "$manifest_latest" | sed -n '1p')"
expected_latest_amd64="$(printf '%s\n' "$manifest_latest" | sed -n '2p')"
expected_latest_arm64="$(printf '%s\n' "$manifest_latest" | sed -n '3p')"

[[ "$latest_version" == "$expected_latest" ]] ||
    die "updater without a version pinned ${latest_version}, manifest latest is ${expected_latest}"
[[ "$latest_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "updater without a version did not write a stable release: ${latest_version}"
[[ "$latest_amd64" == "$expected_latest_amd64" ]] ||
    die "latest amd64 SHA does not match the manifest (dockerfile ${latest_amd64}, manifest ${expected_latest_amd64})"
[[ "$latest_arm64" == "$expected_latest_arm64" ]] ||
    die "latest arm64 SHA does not match the manifest (dockerfile ${latest_arm64}, manifest ${expected_latest_arm64})"

assert_install_lines "$fixture_latest"
normalize_non_herdr_args "$fixture_latest" > "${tmpdir}/after-latest-normalized.txt"
diff -u "${tmpdir}/before-normalized.txt" "${tmpdir}/after-latest-normalized.txt" \
    || die "latest update changed lines other than the herdr ARGs"

printf 'ok: update-herdr.sh with no version pinned stable %s\n' "$latest_version"
printf 'ALL CHECKS PASSED\n'
