#!/usr/bin/env bash
# Structural + network smoke test for the Dagger CLI pin.
# Reads the shipped dev.Dockerfile (not a copy) and asserts a concrete
# Dagger CLI release is installed and that the image build itself
# runs `dagger version`.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${DOCKERFILE:-${repo_root}/dev.Dockerfile}"

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

[[ -f "$dockerfile" ]] || die "Dockerfile not found: $dockerfile"

# --- Dockerfile must install a concrete Dagger CLI release ---
version="$(arg_value DAGGER_CLI_VERSION)"
sha_amd64="$(arg_value DAGGER_CLI_SHA256_AMD64)"
sha_arm64="$(arg_value DAGGER_CLI_SHA256_ARM64)"

[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$ ]] || die "DAGGER_CLI_VERSION must be vX.Y.Z or v1.0.0-beta.N, got: $version"
[[ ${#sha_amd64} -eq 64 ]] || die "amd64 SHA must be 64 hex chars"
[[ ${#sha_arm64} -eq 64 ]] || die "arm64 SHA must be 64 hex chars"
[[ "$sha_amd64" =~ ^[0-9a-f]{64}$ ]] || die "amd64 SHA must be lowercase hex"
[[ "$sha_arm64" =~ ^[0-9a-f]{64}$ ]] || die "arm64 SHA must be lowercase hex"

grep -Fq 'dagger_file="dagger_${DAGGER_CLI_VERSION}_linux_${dagger_arch}.tar.gz"' "$dockerfile" \
    || die "Dockerfile does not download dagger_\${DAGGER_CLI_VERSION}_linux_\${dagger_arch}.tar.gz"
grep -Fq 'https://dl.dagger.io/dagger/releases/${dagger_version}/${dagger_file}' "$dockerfile" \
    || die "Dockerfile does not fetch Dagger CLI from dl.dagger.io/dagger/releases"
grep -Fq 'install -m 0755 /tmp/dagger-cli/dagger /usr/local/bin/dagger' "$dockerfile" \
    || die "Dockerfile does not install /usr/local/bin/dagger"
grep -Fq 'test -x /usr/local/bin/dagger' "$dockerfile" \
    || die "Dockerfile does not assert /usr/local/bin/dagger is executable"
grep -Eq 'dagger version' "$dockerfile" \
    || die "Dockerfile does not invoke dagger version during the image build"
grep -Fq 'grep -F "${DAGGER_CLI_VERSION}"' "$dockerfile" \
    || die "Dockerfile does not check dagger version against the pinned release"

# Live checksums for the pinned versioned archives (the files the Dockerfile fetches).
verify_archive() {
    local arch="$1"
    local expected_sha="$2"
    local file="dagger_${version}_linux_${arch}.tar.gz"
    local url="https://dl.dagger.io/dagger/releases/${version#v}/${file}"
    local actual

    printf 'download: %s\n' "$file"
    actual="$(curl -fsSL --retry 3 --retry-delay 2 "$url" | sha256_stream)"
    [[ "$actual" == "$expected_sha" ]] || die "${file}: digest mismatch (expected ${expected_sha}, got ${actual})"
    printf 'ok: %s digest\n' "$file"
}

verify_archive "amd64" "$sha_amd64"
verify_archive "arm64" "$sha_arm64"

printf 'ok: Dagger CLI %s is pinned with in-build version check\n' "$version"
printf 'ALL CHECKS PASSED\n'
