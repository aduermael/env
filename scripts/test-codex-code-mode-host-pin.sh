#!/usr/bin/env bash
# Structural + network smoke test for the Codex package pin.
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

# --- Dockerfile must install the complete package, not the bare CLI binary ---
grep -Fq 'codex_asset="codex-package-${codex_target}.tar.gz"' "$dockerfile" \
    || die "Dockerfile does not fetch codex-package-\${codex_target}.tar.gz"
grep -Fq 'codex_root="/usr/local/lib/codex/${codex_version}-${codex_target}"' "$dockerfile" \
    || die "Dockerfile does not install the Codex package under /usr/local/lib/codex"
grep -Fq 'ln -sfn /usr/local/lib/codex/current/bin/codex /usr/local/bin/codex' "$dockerfile" \
    || die "Dockerfile does not point /usr/local/bin/codex at the package binary"
grep -Fq 'ln -sfn /usr/local/lib/codex/current/bin/codex-code-mode-host /usr/local/bin/codex-code-mode-host' "$dockerfile" \
    || die "Dockerfile does not point /usr/local/bin/codex-code-mode-host at the package binary"
grep -Fq 'test -f "${codex_root}/codex-package.json"' "$dockerfile" \
    || die "Dockerfile does not require codex-package.json"
grep -Fq 'test -x "${codex_root}/codex-path/rg"' "$dockerfile" \
    || die "Dockerfile does not require packaged rg"
grep -Fq 'test -x "${codex_root}/codex-resources/bwrap"' "$dockerfile" \
    || die "Dockerfile does not require packaged bwrap"
grep -Fq 'test -x /usr/local/bin/codex-code-mode-host' "$dockerfile" \
    || die "Dockerfile does not assert host executable after install"
grep -Fq 'ln -sfn ../bin/codex-code-mode-host /usr/local/libexec/codex-code-mode-host' "$dockerfile" \
    || die "Dockerfile does not symlink Codex code-mode host into /usr/local/libexec"

tag="$(arg_value CODEX_VERSION)"
cli_sha_amd64="$(arg_value CODEX_SHA256_AMD64)"
cli_sha_arm64="$(arg_value CODEX_SHA256_ARM64)"

[[ "$tag" == rust-v* ]] || die "CODEX_VERSION must be a rust-v* tag, got: $tag"
[[ ${#cli_sha_amd64} -eq 64 ]] || die "package amd64 SHA must be 64 hex chars"
[[ ${#cli_sha_arm64} -eq 64 ]] || die "package arm64 SHA must be 64 hex chars"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/test-codex-code-mode-host.XXXXXX")"
base="https://github.com/${codex_repo}/releases/download/${tag}"
version="${tag#rust-v}"

verify_package() {
    local asset="$1"
    local expected_sha="$2"
    local path="${tmpdir}/${asset}"
    local listing entry manifest

    printf 'download: %s\n' "$asset"
    curl -fsSL --retry 3 --retry-delay 2 -o "$path" "${base}/${asset}"
    local actual
    actual="$(sha256_file "$path")"
    [[ "$actual" == "$expected_sha" ]] || die "${asset}: digest mismatch (expected ${expected_sha}, got ${actual})"
    listing="$(tar -tzf "$path")"
    for entry in \
        codex-package.json \
        bin/codex \
        bin/codex-code-mode-host \
        codex-path/rg \
        codex-resources/bwrap
    do
        grep -Fxq "$entry" <<< "$listing" || die "${asset}: missing entry ${entry}"
    done
    manifest="$(tar -xOzf "$path" codex-package.json)"
    grep -Fq "\"version\": \"${version}\"" <<< "$manifest" || die "${asset}: manifest version is not ${version}"
    printf 'ok: %s digest + package entries\n' "$asset"
}

verify_package "codex-package-x86_64-unknown-linux-musl.tar.gz" "$cli_sha_amd64"
verify_package "codex-package-aarch64-unknown-linux-musl.tar.gz" "$cli_sha_arm64"

# --- update-codex.sh must rewrite package SHA ARGs (exercise real script on a fixture copy) ---
fixture_df="${tmpdir}/dev.Dockerfile"
cp "$dockerfile" "$fixture_df"
sed -i \
    -e 's/^ARG CODEX_SHA256_AMD64=.*/ARG CODEX_SHA256_AMD64=0000000000000000000000000000000000000000000000000000000000000000/' \
    -e 's/^ARG CODEX_SHA256_ARM64=.*/ARG CODEX_SHA256_ARM64=1111111111111111111111111111111111111111111111111111111111111111/' \
    "$fixture_df"

DOCKERFILE="$fixture_df" bash "$update_script" "$tag"

rewritten_cli_amd64="$(DOCKERFILE="$fixture_df" bash -c 'grep -E "^ARG CODEX_SHA256_AMD64=" "$DOCKERFILE" | cut -d= -f2')"
rewritten_cli_arm64="$(DOCKERFILE="$fixture_df" bash -c 'grep -E "^ARG CODEX_SHA256_ARM64=" "$DOCKERFILE" | cut -d= -f2')"
rewritten_version="$(DOCKERFILE="$fixture_df" bash -c 'grep -E "^ARG CODEX_VERSION=" "$DOCKERFILE" | cut -d= -f2')"

[[ "$rewritten_version" == "$tag" ]] || die "update-codex.sh did not keep CODEX_VERSION=${tag}"
[[ "$rewritten_cli_amd64" == "$cli_sha_amd64" ]] || die "update-codex.sh did not restore package amd64 SHA (got ${rewritten_cli_amd64})"
[[ "$rewritten_cli_arm64" == "$cli_sha_arm64" ]] || die "update-codex.sh did not restore package arm64 SHA (got ${rewritten_cli_arm64})"
grep -Fq 'codex_asset="codex-package-${codex_target}.tar.gz"' "$fixture_df" \
    || die "update-codex.sh rewrite dropped package install"
grep -Fq 'ln -sfn /usr/local/lib/codex/current/bin/codex-code-mode-host /usr/local/bin/codex-code-mode-host' "$fixture_df" \
    || die "update-codex.sh rewrite dropped host install line"

printf 'ok: update-codex.sh rewrote package SHA ARGs for %s\n' "$tag"
printf 'ALL CHECKS PASSED\n'
