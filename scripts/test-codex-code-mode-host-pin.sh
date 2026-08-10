#!/usr/bin/env bash
# Structural + network smoke test for the Codex code-mode host pin.
# Drives the real dev.Dockerfile ARGs and scripts/update-codex.sh helpers
# against live GitHub release assets for the pinned tag.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${DOCKERFILE:-${repo_root}/dev.Dockerfile}"
update_script="${repo_root}/scripts/update-codex.sh"
codex_repo="${CODEX_REPO:-openai/codex}"
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

arg_value() {
    local name="$1"
    local line
    line="$(grep -E "^ARG ${name}=" "$dockerfile" || true)"
    [[ -n "$line" ]] || die "missing ARG ${name}= in ${dockerfile}"
    printf '%s\n' "${line#ARG ${name}=}"
}

require_command curl
require_command grep
require_command tar
require_command awk
require_command mktemp
require_command bash

[[ -f "$dockerfile" ]] || die "Dockerfile not found: $dockerfile"
[[ -f "$update_script" ]] || die "update script not found: $update_script"

bash -n "$update_script" || die "bash -n failed for update-codex.sh"

# --- Dockerfile must install both binaries ---
grep -Fq 'install -m 0755 "/tmp/codex/codex-${codex_target}" /usr/local/bin/codex' "$dockerfile" \
    || die "Dockerfile does not install /usr/local/bin/codex from codex archive"
grep -Fq 'host_asset="codex-code-mode-host-${codex_target}.tar.gz"' "$dockerfile" \
    || die "Dockerfile does not fetch codex-code-mode-host-\${codex_target}.tar.gz"
grep -Fq 'install -m 0755 "/tmp/codex-code-mode-host/codex-code-mode-host-${codex_target}" /usr/local/bin/codex-code-mode-host' "$dockerfile" \
    || die "Dockerfile does not install /usr/local/bin/codex-code-mode-host"
grep -Fq 'test -x /usr/local/bin/codex-code-mode-host' "$dockerfile" \
    || die "Dockerfile does not assert host executable after install"

tag="$(arg_value CODEX_VERSION)"
host_sha_amd64="$(arg_value CODEX_CODE_MODE_HOST_SHA256_AMD64)"
host_sha_arm64="$(arg_value CODEX_CODE_MODE_HOST_SHA256_ARM64)"
cli_sha_amd64="$(arg_value CODEX_SHA256_AMD64)"
cli_sha_arm64="$(arg_value CODEX_SHA256_ARM64)"

[[ "$tag" == rust-v* ]] || die "CODEX_VERSION must be a rust-v* tag, got: $tag"
[[ ${#host_sha_amd64} -eq 64 ]] || die "host amd64 SHA must be 64 hex chars"
[[ ${#host_sha_arm64} -eq 64 ]] || die "host arm64 SHA must be 64 hex chars"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/test-codex-code-mode-host.XXXXXX")"
base="https://github.com/${codex_repo}/releases/download/${tag}"

verify_asset() {
    local asset="$1"
    local expected_sha="$2"
    local expected_entry="$3"
    local path="${tmpdir}/${asset}"

    printf 'download: %s\n' "$asset"
    curl -fsSL --retry 3 --retry-delay 2 -o "$path" "${base}/${asset}"
    local actual
    actual="$(sha256_file "$path")"
    [[ "$actual" == "$expected_sha" ]] || die "${asset}: digest mismatch (expected ${expected_sha}, got ${actual})"
    tar -tzf "$path" | grep -Fxq "$expected_entry" || die "${asset}: missing entry ${expected_entry}"
    printf 'ok: %s digest + entry %s\n' "$asset" "$expected_entry"
}

verify_asset "codex-code-mode-host-x86_64-unknown-linux-musl.tar.gz" \
    "$host_sha_amd64" "codex-code-mode-host-x86_64-unknown-linux-musl"
verify_asset "codex-code-mode-host-aarch64-unknown-linux-musl.tar.gz" \
    "$host_sha_arm64" "codex-code-mode-host-aarch64-unknown-linux-musl"
verify_asset "codex-x86_64-unknown-linux-musl.tar.gz" \
    "$cli_sha_amd64" "codex-x86_64-unknown-linux-musl"
verify_asset "codex-aarch64-unknown-linux-musl.tar.gz" \
    "$cli_sha_arm64" "codex-aarch64-unknown-linux-musl"

# --- update-codex.sh must rewrite host ARGs (exercise real script on a fixture copy) ---
fixture_df="${tmpdir}/dev.Dockerfile"
cp "$dockerfile" "$fixture_df"
# Corrupt host SHAs so a successful rewrite is observable
sed -i \
    -e 's/^ARG CODEX_CODE_MODE_HOST_SHA256_AMD64=.*/ARG CODEX_CODE_MODE_HOST_SHA256_AMD64=0000000000000000000000000000000000000000000000000000000000000000/' \
    -e 's/^ARG CODEX_CODE_MODE_HOST_SHA256_ARM64=.*/ARG CODEX_CODE_MODE_HOST_SHA256_ARM64=1111111111111111111111111111111111111111111111111111111111111111/' \
    "$fixture_df"

DOCKERFILE="$fixture_df" bash "$update_script" "$tag"

rewritten_host_amd64="$(DOCKERFILE="$fixture_df" bash -c 'grep -E "^ARG CODEX_CODE_MODE_HOST_SHA256_AMD64=" "$DOCKERFILE" | cut -d= -f2')"
rewritten_host_arm64="$(DOCKERFILE="$fixture_df" bash -c 'grep -E "^ARG CODEX_CODE_MODE_HOST_SHA256_ARM64=" "$DOCKERFILE" | cut -d= -f2')"
rewritten_cli_amd64="$(DOCKERFILE="$fixture_df" bash -c 'grep -E "^ARG CODEX_SHA256_AMD64=" "$DOCKERFILE" | cut -d= -f2')"
rewritten_cli_arm64="$(DOCKERFILE="$fixture_df" bash -c 'grep -E "^ARG CODEX_SHA256_ARM64=" "$DOCKERFILE" | cut -d= -f2')"
rewritten_version="$(DOCKERFILE="$fixture_df" bash -c 'grep -E "^ARG CODEX_VERSION=" "$DOCKERFILE" | cut -d= -f2')"

[[ "$rewritten_version" == "$tag" ]] || die "update-codex.sh did not keep CODEX_VERSION=${tag}"
[[ "$rewritten_host_amd64" == "$host_sha_amd64" ]] || die "update-codex.sh did not restore host amd64 SHA (got ${rewritten_host_amd64})"
[[ "$rewritten_host_arm64" == "$host_sha_arm64" ]] || die "update-codex.sh did not restore host arm64 SHA (got ${rewritten_host_arm64})"
[[ "$rewritten_cli_amd64" == "$cli_sha_amd64" ]] || die "update-codex.sh changed CLI amd64 SHA unexpectedly"
[[ "$rewritten_cli_arm64" == "$cli_sha_arm64" ]] || die "update-codex.sh changed CLI arm64 SHA unexpectedly"
# Confirm install path still present after rewrite
grep -Fq 'install -m 0755 "/tmp/codex-code-mode-host/codex-code-mode-host-${codex_target}" /usr/local/bin/codex-code-mode-host' "$fixture_df" \
    || die "update-codex.sh rewrite dropped host install line"

printf 'ok: update-codex.sh rewrote host SHA ARGs for %s\n' "$tag"
printf 'ALL CHECKS PASSED\n'
