#!/usr/bin/env bash
# Structural + network smoke test for the herdr pin.
# Reads the shipped dev.Dockerfile (not a copy) and asserts a concrete
# herdr release is installed and that the image build itself
# runs `herdr --version` against that pin.
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

version="$(arg_value HERDR_VERSION)"
sha_amd64="$(arg_value HERDR_SHA256_AMD64)"
sha_arm64="$(arg_value HERDR_SHA256_ARM64)"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "HERDR_VERSION must be a stable X.Y.Z release, got: $version"
[[ ${#sha_amd64} -eq 64 ]] || die "amd64 SHA must be 64 hex chars"
[[ ${#sha_arm64} -eq 64 ]] || die "arm64 SHA must be 64 hex chars"
[[ "$sha_amd64" =~ ^[0-9a-f]{64}$ ]] || die "amd64 SHA must be lowercase hex"
[[ "$sha_arm64" =~ ^[0-9a-f]{64}$ ]] || die "arm64 SHA must be lowercase hex"

grep -Fq 'amd64|x86_64) herdr_target="linux-x86_64"; herdr_sha256="${HERDR_SHA256_AMD64}"' "$dockerfile" \
    || die "Dockerfile does not map amd64 to herdr-linux-x86_64"
grep -Fq 'arm64|aarch64) herdr_target="linux-aarch64"; herdr_sha256="${HERDR_SHA256_ARM64}"' "$dockerfile" \
    || die "Dockerfile does not map arm64 to herdr-linux-aarch64"
grep -Fq 'herdr_file="herdr-${herdr_target}"' "$dockerfile" \
    || die "Dockerfile does not download herdr-\${herdr_target}"
grep -Fq 'https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/${herdr_file}' "$dockerfile" \
    || die "Dockerfile does not fetch herdr from github.com/herdrdev/herdr/releases"
grep -Fq 'install -m 0755 "/tmp/${herdr_file}" /usr/local/bin/herdr' "$dockerfile" \
    || die "Dockerfile does not install /usr/local/bin/herdr"
grep -Fq 'test -x /usr/local/bin/herdr' "$dockerfile" \
    || die "Dockerfile does not assert /usr/local/bin/herdr is executable"
grep -Fq 'test "$(command -v herdr)" = "/usr/local/bin/herdr"' "$dockerfile" \
    || die "Dockerfile does not install herdr onto PATH"
grep -Fq 'herdr --version' "$dockerfile" \
    || die "Dockerfile does not invoke herdr --version during the image build"
grep -Fq 'grep -Fx "herdr ${HERDR_VERSION}"' "$dockerfile" \
    || die "Dockerfile does not check herdr version against the pinned release"

# Live checksums for the pinned binaries (the files the Dockerfile fetches).
verify_binary() {
    local target="$1"
    local expected_sha="$2"
    local file="herdr-${target}"
    local url="https://github.com/herdrdev/herdr/releases/download/v${version}/${file}"
    local actual

    printf 'download: %s\n' "$file"
    actual="$(curl -fsSL --retry 3 --retry-delay 2 "$url" | sha256_stream)"
    [[ "$actual" == "$expected_sha" ]] || die "${file}: digest mismatch (expected ${expected_sha}, got ${actual})"
    printf 'ok: %s digest match\n' "$file"
}

verify_binary "linux-x86_64" "$sha_amd64"
verify_binary "linux-aarch64" "$sha_arm64"

printf 'ok: herdr %s is pinned with in-build version check\n' "$version"
printf 'ALL CHECKS PASSED\n'
