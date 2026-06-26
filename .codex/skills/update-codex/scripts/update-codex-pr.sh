#!/usr/bin/env bash
set -euo pipefail

repo_root=""
tmpdir=""
worktree=""

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

usage() {
    cat <<'EOF'
Usage: update-codex-pr.sh [latest|VERSION|TAG]

Runs ./scripts/update-codex.sh from a fresh origin/main worktree.
If dev.Dockerfile changes, creates a branch, pushes it, and opens a PR.
EOF
}

dirty_status() {
    git -C "$1" status --porcelain=v1 --untracked-files=normal
}

single_dockerfile_change_only() {
    local line path status
    status="$(git status --porcelain=v1 --untracked-files=normal)"
    [[ -n "$status" ]] || return 1

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        path="${line:3}"
        [[ "$path" == "dev.Dockerfile" ]] || return 1
    done <<< "$status"
}

branch_exists() {
    local branch="$1"
    git show-ref --verify --quiet "refs/heads/${branch}" && return 0
    git ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1
}

sanitize_branch_component() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'
}

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    [[ "$#" -le 1 ]] || {
        usage >&2
        die "expected at most one release argument"
    }

    require_command git
    require_command gh

    local dirty version branch base_branch body_file commit_sha pr_url
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a Git repository"

    [[ -x "${repo_root}/scripts/update-codex.sh" ]] || die "missing executable: ./scripts/update-codex.sh"
    [[ -f "${repo_root}/dev.Dockerfile" ]] || die "missing dev.Dockerfile"

    dirty="$(dirty_status "$repo_root")"
    if [[ -n "$dirty" ]]; then
        printf '%s\n' "$dirty" >&2
        die "working tree is dirty; commit, stash, or remove changes before running this skill"
    fi

    git -C "$repo_root" fetch origin main

    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/update-codex-pr.XXXXXX")"
    worktree="${tmpdir}/worktree"
    body_file="${tmpdir}/pr-body.md"

    cleanup() {
        if [[ -n "${repo_root:-}" && -n "${worktree:-}" ]]; then
            git -C "$repo_root" worktree remove --force "$worktree" >/dev/null 2>&1 || true
        fi
        if [[ -n "${tmpdir:-}" ]]; then
            rm -rf "$tmpdir"
        fi
    }
    trap cleanup EXIT

    git -C "$repo_root" worktree add --detach "$worktree" origin/main

    if [[ "$#" -eq 1 ]]; then
        (cd "$worktree" && ./scripts/update-codex.sh "$1")
    else
        (cd "$worktree" && ./scripts/update-codex.sh)
    fi

    if git -C "$worktree" diff --quiet -- dev.Dockerfile; then
        printf 'no update detected: dev.Dockerfile is unchanged\n'
        exit 0
    fi

    (cd "$worktree" && single_dockerfile_change_only) || {
        git -C "$worktree" status --short >&2
        die "updater changed files other than dev.Dockerfile"
    }

    version="$(sed -n 's/^ARG CODEX_VERSION=//p' "${worktree}/dev.Dockerfile" | head -n 1)"
    [[ -n "$version" ]] || die "could not read CODEX_VERSION from dev.Dockerfile"

    base_branch="update-codex-$(sanitize_branch_component "$version")"
    branch="$base_branch"
    if (cd "$worktree" && branch_exists "$branch"); then
        branch="${base_branch}-$(date -u +%Y%m%d%H%M%S)"
    fi

    git -C "$worktree" switch -c "$branch"
    git -C "$worktree" add dev.Dockerfile
    git -C "$worktree" commit -m "Update Codex to ${version}"
    git -C "$worktree" push -u origin "$branch"

    cat > "$body_file" <<EOF
## Summary
- update Codex to ${version} in the dev image
- update amd64 and arm64 checksums for the new release

## Tests
- ./scripts/update-codex.sh${1:+ $1}
EOF

    pr_url="$(git -C "$worktree" rev-parse --show-toplevel >/dev/null && cd "$worktree" && gh pr create --base main --head "$branch" --title "Update Codex to ${version}" --body-file "$body_file")"
    commit_sha="$(git -C "$worktree" rev-parse --short HEAD)"

    printf 'branch: %s\n' "$branch"
    printf 'commit: %s\n' "$commit_sha"
    printf 'pr: %s\n' "$pr_url"
}

main "$@"
