#!/usr/bin/env bash
# Structural + network smoke test for scripts/update-gh.sh.
# Drives the shipped updater against a fixture copy of dev.Dockerfile:
# corrupt the GitHub CLI SHA ARGs, pin the currently shipped GITHUB_CLI_VERSION,
# and assert the version is unchanged while both SHA ARGs are restored to the
# live GitHub CLI release digests.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${DOCKERFILE:-${repo_root}/dev.Dockerfile}"
update_script="${repo_root}/scripts/update-gh.sh"
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

require_command grep
require_command awk
require_command mktemp
require_command bash
require_command sed

[[ -f "$dockerfile" ]] || die "Dockerfile not found: $dockerfile"
[[ -f "$update_script" ]] || die "update script not found: $update_script"
[[ -f "$pr_runner" ]] || die "PR runner not found: $pr_runner"

bash -n "$update_script" || die "bash -n failed for update-gh.sh"
bash -n "$pr_runner" || die "bash -n failed for update-software-pr.sh"

version="$(arg_value GITHUB_CLI_VERSION)"
sha_amd64="$(arg_value GITHUB_CLI_SHA256_AMD64)"
sha_arm64="$(arg_value GITHUB_CLI_SHA256_ARM64)"

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "GITHUB_CLI_VERSION must be X.Y.Z, got: $version"
[[ "$sha_amd64" =~ ^[0-9a-f]{64}$ ]] || die "amd64 SHA must be lowercase hex"
[[ "$sha_arm64" =~ ^[0-9a-f]{64}$ ]] || die "arm64 SHA must be lowercase hex"

# Expected digests come from the shipped Dockerfile pin, not a hardcoded
# constant. The updater re-downloads the live GitHub CLI archives for this
# version and must restore those same checksums.
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/test-update-gh.XXXXXX")"
fixture_df="${tmpdir}/dev.Dockerfile"
cp "$dockerfile" "$fixture_df"

# Corrupt GitHub CLI SHAs so a successful rewrite is observable
sed -i \
    -e 's/^ARG GITHUB_CLI_SHA256_AMD64=.*/ARG GITHUB_CLI_SHA256_AMD64=0000000000000000000000000000000000000000000000000000000000000000/' \
    -e 's/^ARG GITHUB_CLI_SHA256_ARM64=.*/ARG GITHUB_CLI_SHA256_ARM64=1111111111111111111111111111111111111111111111111111111111111111/' \
    "$fixture_df"

[[ "$(arg_value GITHUB_CLI_SHA256_AMD64 "$fixture_df")" == "0000000000000000000000000000000000000000000000000000000000000000" ]] \
    || die "failed to corrupt fixture amd64 SHA"
[[ "$(arg_value GITHUB_CLI_SHA256_ARM64 "$fixture_df")" == "1111111111111111111111111111111111111111111111111111111111111111" ]] \
    || die "failed to corrupt fixture arm64 SHA"

DOCKERFILE="$fixture_df" bash "$update_script" "v${version}"

rewritten_version="$(arg_value GITHUB_CLI_VERSION "$fixture_df")"
rewritten_amd64="$(arg_value GITHUB_CLI_SHA256_AMD64 "$fixture_df")"
rewritten_arm64="$(arg_value GITHUB_CLI_SHA256_ARM64 "$fixture_df")"

[[ "$rewritten_version" == "$version" ]] || die "update-gh.sh did not keep GITHUB_CLI_VERSION=${version} (got ${rewritten_version})"
[[ "$rewritten_amd64" == "$sha_amd64" ]] || die "update-gh.sh did not restore amd64 SHA to live digest (got ${rewritten_amd64})"
[[ "$rewritten_arm64" == "$sha_arm64" ]] || die "update-gh.sh did not restore arm64 SHA to live digest (got ${rewritten_arm64})"

grep -Fq 'gh_file="gh_${GITHUB_CLI_VERSION}_linux_${gh_arch}.tar.gz"' "$fixture_df" \
    || die "update-gh.sh rewrite dropped GitHub CLI archive filename line"
grep -Fq 'https://github.com/cli/cli/releases/download/v${GITHUB_CLI_VERSION}/${gh_file}' "$fixture_df" \
    || die "update-gh.sh rewrite dropped GitHub CLI download URL"
grep -Fq 'install -m 0755 /tmp/gh/bin/gh /usr/local/bin/gh' "$fixture_df" \
    || die "update-gh.sh rewrite dropped gh install line"

printf 'ok: update-gh.sh restored GitHub CLI SHA ARGs for %s\n' "$version"
printf 'ALL CHECKS PASSED\n'
