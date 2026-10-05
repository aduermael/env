#!/usr/bin/env bash
# Structural + network smoke test for the Terraform pin.
# Reads the shipped dev.Dockerfile (not a copy) and asserts a concrete
# Terraform release is installed and that the image build itself
# runs `terraform version` against that pin.
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

version="$(arg_value TERRAFORM_VERSION)"
sha_amd64="$(arg_value TERRAFORM_SHA256_AMD64)"
sha_arm64="$(arg_value TERRAFORM_SHA256_ARM64)"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "TERRAFORM_VERSION must be a stable X.Y.Z release, got: $version"
[[ ${#sha_amd64} -eq 64 ]] || die "amd64 SHA must be 64 hex chars"
[[ ${#sha_arm64} -eq 64 ]] || die "arm64 SHA must be 64 hex chars"
[[ "$sha_amd64" =~ ^[0-9a-f]{64}$ ]] || die "amd64 SHA must be lowercase hex"
[[ "$sha_arm64" =~ ^[0-9a-f]{64}$ ]] || die "arm64 SHA must be lowercase hex"

grep -Fq 'terraform_file="terraform_${TERRAFORM_VERSION}_linux_${terraform_arch}.zip"' "$dockerfile" \
    || die "Dockerfile does not download terraform_\${TERRAFORM_VERSION}_linux_\${terraform_arch}.zip"
grep -Fq 'https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/${terraform_file}' "$dockerfile" \
    || die "Dockerfile does not fetch Terraform from releases.hashicorp.com/terraform"
grep -Fq 'install -m 0755 /tmp/terraform-cli/terraform /usr/local/bin/terraform' "$dockerfile" \
    || die "Dockerfile does not install /usr/local/bin/terraform"
grep -Fq 'test -x /usr/local/bin/terraform' "$dockerfile" \
    || die "Dockerfile does not assert /usr/local/bin/terraform is executable"
grep -Fq 'test "$(command -v terraform)" = "/usr/local/bin/terraform"' "$dockerfile" \
    || die "Dockerfile does not install terraform onto PATH"
grep -Eq 'terraform version' "$dockerfile" \
    || die "Dockerfile does not invoke terraform version during the image build"
grep -Fq 'grep -F "Terraform v${TERRAFORM_VERSION}"' "$dockerfile" \
    || die "Dockerfile does not check terraform version against the pinned release"

# Live checksums for the pinned versioned zips (the files the Dockerfile fetches).
verify_archive() {
    local arch="$1"
    local expected_sha="$2"
    local file="terraform_${version}_linux_${arch}.zip"
    local url="https://releases.hashicorp.com/terraform/${version}/${file}"
    local actual

    printf 'download: %s\n' "$file"
    actual="$(curl -fsSL --retry 3 --retry-delay 2 "$url" | sha256_stream)"
    [[ "$actual" == "$expected_sha" ]] || die "${file}: digest mismatch (expected ${expected_sha}, got ${actual})"
    printf 'ok: %s digest match\n' "$file"
}

verify_archive "amd64" "$sha_amd64"
verify_archive "arm64" "$sha_arm64"

printf 'ok: terraform %s is pinned with in-build version check\n' "$version"
printf 'ALL CHECKS PASSED\n'
