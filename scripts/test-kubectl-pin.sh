#!/usr/bin/env bash
# Structural + network smoke test for the kubectl pin.
# Reads the shipped dev.Dockerfile (not a copy) and asserts a concrete
# kubectl release is installed and that the image build itself
# runs `kubectl version --client`.
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

# --- Dockerfile must install a concrete kubectl release ---
version="$(arg_value KUBECTL_VERSION)"
sha_amd64="$(arg_value KUBECTL_SHA256_AMD64)"
sha_arm64="$(arg_value KUBECTL_SHA256_ARM64)"

[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "KUBECTL_VERSION must be vX.Y.Z, got: $version"
[[ ${#sha_amd64} -eq 64 ]] || die "amd64 SHA must be 64 hex chars"
[[ ${#sha_arm64} -eq 64 ]] || die "arm64 SHA must be 64 hex chars"
[[ "$sha_amd64" =~ ^[0-9a-f]{64}$ ]] || die "amd64 SHA must be lowercase hex"
[[ "$sha_arm64" =~ ^[0-9a-f]{64}$ ]] || die "arm64 SHA must be lowercase hex"

grep -Fq 'kubectl_url="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${kubectl_arch}/kubectl"' "$dockerfile" \
    || die "Dockerfile does not fetch kubectl from dl.k8s.io/release/\${KUBECTL_VERSION}"
grep -Fq 'install -m 0755 /tmp/kubectl /usr/local/bin/kubectl' "$dockerfile" \
    || die "Dockerfile does not install /usr/local/bin/kubectl"
grep -Fq 'test -x /usr/local/bin/kubectl' "$dockerfile" \
    || die "Dockerfile does not assert /usr/local/bin/kubectl is executable"
grep -Eq 'kubectl version --client' "$dockerfile" \
    || die "Dockerfile does not invoke kubectl version --client during the image build"
grep -Fq 'grep -F "Client Version: ${KUBECTL_VERSION}"' "$dockerfile" \
    || die "Dockerfile does not check kubectl version against the pinned release"

# Live checksums for the pinned versioned binaries (the files the Dockerfile fetches).
verify_binary() {
    local arch="$1"
    local expected_sha="$2"
    local url="https://dl.k8s.io/release/${version}/bin/linux/${arch}/kubectl"
    local actual

    printf 'download: kubectl-%s-linux-%s\n' "$version" "$arch"
    actual="$(curl -fsSL --retry 3 --retry-delay 2 "$url" | sha256_stream)"
    [[ "$actual" == "$expected_sha" ]] || die "kubectl ${version} linux/${arch}: digest mismatch (expected ${expected_sha}, got ${actual})"
    printf 'ok: kubectl %s linux/%s digest\n' "$version" "$arch"
}

verify_binary "amd64" "$sha_amd64"
verify_binary "arm64" "$sha_arm64"

printf 'ok: kubectl %s is pinned with in-build version check\n' "$version"
printf 'ALL CHECKS PASSED\n'
