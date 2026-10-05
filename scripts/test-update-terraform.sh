#!/usr/bin/env bash
# Structural + network smoke test for scripts/update-terraform.sh.
# Drives the shipped updater against a fixture copy of dev.Dockerfile.
# 1. Corrupt the Terraform SHA ARGs, pin the shipped TERRAFORM_VERSION, and
#    assert both SHA ARGs are restored to the live HashiCorp release digests
#    while the install and version-check lines stay in place.
# 2. Run the updater with no version argument and assert it writes a stable
#    release whose checksums match the official artifacts.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${DOCKERFILE:-${repo_root}/dev.Dockerfile}"
update_script="${repo_root}/scripts/update-terraform.sh"
pr_runner="${repo_root}/.codex/skills/update-software/scripts/update-software-pr.sh"
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

sha256_stream() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    else
        die "required command not found: sha256sum or shasum"
    fi
}

normalize_non_terraform_args() {
    awk '
        /^ARG TERRAFORM_VERSION=/ { print "ARG TERRAFORM_VERSION=<version>"; next }
        /^ARG TERRAFORM_SHA256_AMD64=/ { print "ARG TERRAFORM_SHA256_AMD64=<amd64>"; next }
        /^ARG TERRAFORM_SHA256_ARM64=/ { print "ARG TERRAFORM_SHA256_ARM64=<arm64>"; next }
        { print }
    ' "$1"
}

assert_install_lines() {
    local file="$1"
    grep -Fq 'terraform_file="terraform_${TERRAFORM_VERSION}_linux_${terraform_arch}.zip"' "$file" \
        || die "update-terraform.sh rewrite dropped Terraform archive filename line"
    grep -Fq 'https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/${terraform_file}' "$file" \
        || die "update-terraform.sh rewrite dropped Terraform download URL"
    grep -Fq 'install -m 0755 /tmp/terraform-cli/terraform /usr/local/bin/terraform' "$file" \
        || die "update-terraform.sh rewrite dropped terraform install line"
    grep -Fq 'grep -F "Terraform v${TERRAFORM_VERSION}"' "$file" \
        || die "update-terraform.sh rewrite dropped terraform version check"
}

live_digest() {
    local version="$1"
    local arch="$2"
    local file="terraform_${version}_linux_${arch}.zip"
    local url="https://releases.hashicorp.com/terraform/${version}/${file}"
    printf 'download: %s\n' "$file" >&2
    curl -fsSL --retry 3 --retry-delay 2 "$url" | sha256_stream
}

require_command grep
require_command awk
require_command mktemp
require_command bash
require_command sed
require_command curl
require_command diff

[[ -f "$dockerfile" ]] || die "Dockerfile not found: $dockerfile"
[[ -f "$update_script" ]] || die "update script not found: $update_script"
[[ -f "$pr_runner" ]] || die "PR runner not found: $pr_runner"

bash -n "$update_script" || die "bash -n failed for update-terraform.sh"
bash -n "$pr_runner" || die "bash -n failed for update-software-pr.sh"

version="$(arg_value TERRAFORM_VERSION)"
sha_amd64="$(arg_value TERRAFORM_SHA256_AMD64)"
sha_arm64="$(arg_value TERRAFORM_SHA256_ARM64)"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "TERRAFORM_VERSION must be a stable X.Y.Z release, got: $version"
[[ "$sha_amd64" =~ ^[0-9a-f]{64}$ ]] || die "amd64 SHA must be lowercase hex"
[[ "$sha_arm64" =~ ^[0-9a-f]{64}$ ]] || die "arm64 SHA must be lowercase hex"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/test-update-terraform.XXXXXX")"
fixture_df="${tmpdir}/dev.Dockerfile"
cp "$dockerfile" "$fixture_df"
normalize_non_terraform_args "$fixture_df" > "${tmpdir}/before-normalized.txt"

sed -i \
    -e 's/^ARG TERRAFORM_SHA256_AMD64=.*/ARG TERRAFORM_SHA256_AMD64=0000000000000000000000000000000000000000000000000000000000000000/' \
    -e 's/^ARG TERRAFORM_SHA256_ARM64=.*/ARG TERRAFORM_SHA256_ARM64=1111111111111111111111111111111111111111111111111111111111111111/' \
    "$fixture_df"

[[ "$(arg_value TERRAFORM_SHA256_AMD64 "$fixture_df")" == "0000000000000000000000000000000000000000000000000000000000000000" ]] \
    || die "failed to corrupt fixture amd64 SHA"
[[ "$(arg_value TERRAFORM_SHA256_ARM64 "$fixture_df")" == "1111111111111111111111111111111111111111111111111111111111111111" ]] \
    || die "failed to corrupt fixture arm64 SHA"

DOCKERFILE="$fixture_df" bash "$update_script" "$version"

rewritten_version="$(arg_value TERRAFORM_VERSION "$fixture_df")"
rewritten_amd64="$(arg_value TERRAFORM_SHA256_AMD64 "$fixture_df")"
rewritten_arm64="$(arg_value TERRAFORM_SHA256_ARM64 "$fixture_df")"

[[ "$rewritten_version" == "$version" ]] || die "update-terraform.sh did not keep TERRAFORM_VERSION=${version} (got ${rewritten_version})"
[[ "$rewritten_amd64" == "$sha_amd64" ]] || die "update-terraform.sh did not restore amd64 SHA (got ${rewritten_amd64})"
[[ "$rewritten_arm64" == "$sha_arm64" ]] || die "update-terraform.sh did not restore arm64 SHA (got ${rewritten_arm64})"

live_amd64="$(live_digest "$version" "amd64")"
live_arm64="$(live_digest "$version" "arm64")"
[[ "$rewritten_amd64" == "$live_amd64" ]] || die "pinned amd64 SHA is not the live digest (dockerfile ${rewritten_amd64}, live ${live_amd64})"
[[ "$rewritten_arm64" == "$live_arm64" ]] || die "pinned arm64 SHA is not the live digest (dockerfile ${rewritten_arm64}, live ${live_arm64})"
printf 'ok: terraform_%s_linux_amd64.zip digest match\n' "$version"
printf 'ok: terraform_%s_linux_arm64.zip digest match\n' "$version"

assert_install_lines "$fixture_df"
normalize_non_terraform_args "$fixture_df" > "${tmpdir}/after-pinned-normalized.txt"
diff -u "${tmpdir}/before-normalized.txt" "${tmpdir}/after-pinned-normalized.txt" \
    || die "pinned update changed lines other than the Terraform ARGs"

printf 'ok: update-terraform.sh restored Terraform SHA ARGs for %s\n' "$version"

# No version argument: newest stable release, checksums from the official zips.
fixture_latest="${tmpdir}/dev.Dockerfile.latest"
cp "$dockerfile" "$fixture_latest"
sed -i \
    -e 's/^ARG TERRAFORM_SHA256_AMD64=.*/ARG TERRAFORM_SHA256_AMD64=0000000000000000000000000000000000000000000000000000000000000000/' \
    -e 's/^ARG TERRAFORM_SHA256_ARM64=.*/ARG TERRAFORM_SHA256_ARM64=1111111111111111111111111111111111111111111111111111111111111111/' \
    "$fixture_latest"

DOCKERFILE="$fixture_latest" bash "$update_script"

latest_version="$(arg_value TERRAFORM_VERSION "$fixture_latest")"
latest_amd64="$(arg_value TERRAFORM_SHA256_AMD64 "$fixture_latest")"
latest_arm64="$(arg_value TERRAFORM_SHA256_ARM64 "$fixture_latest")"

[[ "$latest_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "updater without a version did not write a stable release: ${latest_version}"
[[ "$latest_amd64" =~ ^[0-9a-f]{64}$ ]] || die "latest amd64 SHA is not lowercase hex: ${latest_amd64}"
[[ "$latest_arm64" =~ ^[0-9a-f]{64}$ ]] || die "latest arm64 SHA is not lowercase hex: ${latest_arm64}"
[[ "$latest_amd64" != "0000000000000000000000000000000000000000000000000000000000000000" ]] \
    || die "updater without a version left the corrupted amd64 SHA in place"
[[ "$latest_arm64" != "1111111111111111111111111111111111111111111111111111111111111111" ]] \
    || die "updater without a version left the corrupted arm64 SHA in place"

live_latest_amd64="$(live_digest "$latest_version" "amd64")"
live_latest_arm64="$(live_digest "$latest_version" "arm64")"
[[ "$latest_amd64" == "$live_latest_amd64" ]] || die "latest amd64 SHA is not the live digest (dockerfile ${latest_amd64}, live ${live_latest_amd64})"
[[ "$latest_arm64" == "$live_latest_arm64" ]] || die "latest arm64 SHA is not the live digest (dockerfile ${latest_arm64}, live ${live_latest_arm64})"
printf 'ok: latest terraform %s linux/amd64 digest match\n' "$latest_version"
printf 'ok: latest terraform %s linux/arm64 digest match\n' "$latest_version"

assert_install_lines "$fixture_latest"
normalize_non_terraform_args "$fixture_latest" > "${tmpdir}/after-latest-normalized.txt"
diff -u "${tmpdir}/before-normalized.txt" "${tmpdir}/after-latest-normalized.txt" \
    || die "latest update changed lines other than the Terraform ARGs"

printf 'ok: update-terraform.sh with no version pinned stable %s\n' "$latest_version"
printf 'ALL CHECKS PASSED\n'
