#!/usr/bin/env bash
# Structural + network smoke test for the gke-gcloud-auth-plugin pin.
# Reads the shipped dev.Dockerfile (not a copy) and asserts a concrete
# Google Cloud CLI packager release is installed and that the image build
# itself runs `gke-gcloud-auth-plugin --version`.
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

# --- Dockerfile must install a concrete gke-gcloud-auth-plugin release ---
version="$(arg_value GKE_GCLOUD_AUTH_PLUGIN_VERSION)"
sha_amd64="$(arg_value GKE_GCLOUD_AUTH_PLUGIN_SHA256_AMD64)"
sha_arm64="$(arg_value GKE_GCLOUD_AUTH_PLUGIN_SHA256_ARM64)"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "GKE_GCLOUD_AUTH_PLUGIN_VERSION must be X.Y.Z, got: $version"
[[ ${#sha_amd64} -eq 64 ]] || die "amd64 SHA must be 64 hex chars"
[[ ${#sha_arm64} -eq 64 ]] || die "arm64 SHA must be 64 hex chars"
[[ "$sha_amd64" =~ ^[0-9a-f]{64}$ ]] || die "amd64 SHA must be lowercase hex"
[[ "$sha_arm64" =~ ^[0-9a-f]{64}$ ]] || die "arm64 SHA must be lowercase hex"

grep -Fq 'plugin_file="google-cloud-cli-gke-gcloud-auth-plugin_${GKE_GCLOUD_AUTH_PLUGIN_VERSION}.orig_${plugin_arch}.tar.gz"' "$dockerfile" \
    || die "Dockerfile does not download google-cloud-cli-gke-gcloud-auth-plugin_\${GKE_GCLOUD_AUTH_PLUGIN_VERSION}.orig_\${plugin_arch}.tar.gz"
grep -Fq 'https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/for_packagers/linux/${plugin_file}' "$dockerfile" \
    || die "Dockerfile does not fetch gke-gcloud-auth-plugin from Google's rapid-channel packager downloads"
grep -Fq 'tar -xzf "/tmp/${plugin_file}" -C /usr/local --no-same-owner' "$dockerfile" \
    || die "Dockerfile does not extract gke-gcloud-auth-plugin into /usr/local"
grep -Fq 'test -x /usr/local/google-cloud-sdk/bin/gke-gcloud-auth-plugin' "$dockerfile" \
    || die "Dockerfile does not assert /usr/local/google-cloud-sdk/bin/gke-gcloud-auth-plugin is executable"
grep -Fq 'ENV PATH="/usr/local/google-cloud-sdk/bin:${PATH}"' "$dockerfile" \
    || die "Dockerfile does not put google-cloud-sdk/bin on PATH"
grep -Eq 'gke-gcloud-auth-plugin --version' "$dockerfile" \
    || die "Dockerfile does not invoke gke-gcloud-auth-plugin --version during the image build"
grep -Fq 'grep -Fq "\"version\": \"${GKE_GCLOUD_AUTH_PLUGIN_VERSION}\"" /usr/local/google-cloud-sdk/.install/gke-gcloud-auth-plugin.snapshot.json' "$dockerfile" \
    || die "Dockerfile does not check gke-gcloud-auth-plugin snapshot version against the pinned release"

# Live checksums for the pinned versioned archives (the files the Dockerfile fetches).
verify_archive() {
    local arch="$1"
    local expected_sha="$2"
    local file="google-cloud-cli-gke-gcloud-auth-plugin_${version}.orig_${arch}.tar.gz"
    local url="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/for_packagers/linux/${file}"
    local actual

    printf 'download: %s\n' "$file"
    actual="$(curl -fsSL --retry 3 --retry-delay 2 "$url" | sha256_stream)"
    [[ "$actual" == "$expected_sha" ]] || die "${file}: digest mismatch (expected ${expected_sha}, got ${actual})"
    printf 'ok: %s digest\n' "$file"
}

verify_archive "amd64" "$sha_amd64"
verify_archive "aarch64" "$sha_arm64"

printf 'ok: gke-gcloud-auth-plugin %s is pinned with in-build version check\n' "$version"
printf 'ALL CHECKS PASSED\n'
