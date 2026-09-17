#!/usr/bin/env bash
# Fixture test for the unified update-software skill runner.
# Drives the shipped runner against a local git fixture for grok, codex,
# cursor, and gcloud-cli: dirty worktree abort, matching updater dispatch,
# and unchanged-Dockerfile no-update path.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pr_runner="${repo_root}/.codex/skills/update-software/scripts/update-software-pr.sh"
packages=(grok codex cursor gcloud-cli)
tmpdir=""

die() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${tmpdir}" && -d "${tmpdir}" ]]; then
        rm -rf "$tmpdir"
    fi
}
trap cleanup EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

write_stub_updater() {
    local dest="$1"
    local name="$2"
    cat > "$dest" <<EOF
#!/usr/bin/env bash
set -euo pipefail
log="\${UPDATE_SOFTWARE_INVOCATION_LOG:?}"
printf '%s\\n' "${name}" >> "\$log"
if [[ "\$#" -gt 0 ]]; then
    printf 'args:%s\\n' "\$*" >> "\$log"
fi
EOF
    chmod +x "$dest"
}

require_command git
require_command bash
require_command mktemp
require_command grep

[[ -f "$pr_runner" ]] || die "PR runner not found: $pr_runner"
[[ -x "$pr_runner" ]] || die "PR runner is not executable: $pr_runner"
bash -n "$pr_runner" || die "bash -n failed for update-software-pr.sh"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/test-update-software.XXXXXX")"
fixture="${tmpdir}/repo"
origin="${tmpdir}/origin.git"
bin_dir="${tmpdir}/bin"
invocation_log="${tmpdir}/invocations.log"
gh_log="${tmpdir}/gh.log"

mkdir -p "$fixture/scripts" "$bin_dir"

cat > "${fixture}/dev.Dockerfile" <<'EOF'
ARG GROK_CLI_VERSION=0.0.0
ARG CODEX_VERSION=0.0.0
ARG CURSOR_CLI_VERSION=0.0.0
ARG GCLOUD_CLI_VERSION=0.0.0
EOF

for pkg in "${packages[@]}"; do
    write_stub_updater "${fixture}/scripts/update-${pkg}.sh" "update-${pkg}.sh"
done

cat > "${bin_dir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${GH_INVOCATION_LOG:-}" ]]; then
    printf '%s\n' "$*" >> "$GH_INVOCATION_LOG"
fi
printf 'error: unexpected gh invocation: %s\n' "$*" >&2
exit 1
EOF
chmod +x "${bin_dir}/gh"

git init -b main "$fixture" >/dev/null
git -C "$fixture" config user.email "update-software-test@example.com"
git -C "$fixture" config user.name "update-software-test"
git -C "$fixture" config commit.gpgsign false
git -C "$fixture" add dev.Dockerfile scripts
git -C "$fixture" commit -m "fixture pins" >/dev/null
git clone --bare "$fixture" "$origin" >/dev/null
git -C "$fixture" remote add origin "$origin"
git -C "$fixture" fetch origin main >/dev/null

export PATH="${bin_dir}:${PATH}"
export UPDATE_SOFTWARE_INVOCATION_LOG="$invocation_log"
export GH_INVOCATION_LOG="$gh_log"
export GIT_TERMINAL_PROMPT=0

run_runner() {
    local pkg="$1"
    local status=0
    local output=""
    set +e
    output="$(
        cd "$fixture" && bash "$pr_runner" "$pkg" 2>&1
    )"
    status=$?
    set -e
    RUNNER_STATUS="$status"
    RUNNER_OUTPUT="$output"
}

assert_no_commit_or_pr() {
    local pkg="$1"
    local extra_branches
    git -C "$fixture" diff --quiet -- dev.Dockerfile \
        || die "${pkg}: fixture dev.Dockerfile changed"
    if [[ -s "$gh_log" ]]; then
        die "${pkg}: gh was invoked: $(cat "$gh_log")"
    fi
    extra_branches="$(git -C "$origin" for-each-ref --format='%(refname:short)' refs/heads | grep -v '^main$' || true)"
    [[ -z "$extra_branches" ]] || die "${pkg}: origin grew extra branches: ${extra_branches}"
}

for pkg in "${packages[@]}"; do
    : > "$invocation_log"
    rm -f "$gh_log"
    printf 'dirty\n' > "${fixture}/dirty.txt"

    run_runner "$pkg"
    [[ "$RUNNER_STATUS" -ne 0 ]] || die "${pkg}: dirty worktree exited 0"
    printf '%s\n' "$RUNNER_OUTPUT" | grep -Fq 'working tree is dirty' \
        || die "${pkg}: dirty worktree output missing dirty-tree error: ${RUNNER_OUTPUT}"
    [[ ! -s "$invocation_log" ]] || die "${pkg}: updater ran on dirty worktree: $(cat "$invocation_log")"
    assert_no_commit_or_pr "$pkg"
    printf 'ok: %s dirty worktree aborts\n' "$pkg"

    rm -f "${fixture}/dirty.txt"
    : > "$invocation_log"
    rm -f "$gh_log"

    run_runner "$pkg"
    [[ "$RUNNER_STATUS" -eq 0 ]] || die "${pkg}: clean no-update exited ${RUNNER_STATUS}: ${RUNNER_OUTPUT}"
    printf '%s\n' "$RUNNER_OUTPUT" | grep -Fq 'no update detected: dev.Dockerfile is unchanged' \
        || die "${pkg}: missing no-update message: ${RUNNER_OUTPUT}"
    [[ "$(cat "$invocation_log")" == "update-${pkg}.sh" ]] \
        || die "${pkg}: expected updater update-${pkg}.sh, got: $(cat "$invocation_log")"
    assert_no_commit_or_pr "$pkg"
    printf 'ok: %s dispatched matching updater and skipped commit/PR\n' "$pkg"
done

printf 'ALL CHECKS PASSED\n'
