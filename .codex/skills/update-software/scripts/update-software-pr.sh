#!/usr/bin/env bash
set -euo pipefail

repo_root=""
tmpdir=""
worktree=""
package=""
updater_rel=""
version_arg=""
display_name=""
checksum_blurb=""

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

usage() {
    cat <<'EOF'
Usage: update-software-pr.sh PACKAGE [latest|VERSION|TAG]

PACKAGE is one of: grok, codex, cursor, gcloud-cli, kubectl, gke-gcloud-auth-plugin

Runs that package's ./scripts/update-*.sh from a fresh origin/main worktree.
If dev.Dockerfile changes, creates a branch, pushes it, and opens a PR.
EOF
}

configure_package() {
    case "$1" in
        grok)
            updater_rel="scripts/update-grok.sh"
            version_arg="GROK_CLI_VERSION"
            display_name="Grok Build"
            checksum_blurb="update amd64 and arm64 checksums for the new release"
            ;;
        codex)
            updater_rel="scripts/update-codex.sh"
            version_arg="CODEX_VERSION"
            display_name="Codex"
            checksum_blurb="update amd64 and arm64 checksums for the new release"
            ;;
        cursor)
            updater_rel="scripts/update-cursor.sh"
            version_arg="CURSOR_CLI_VERSION"
            display_name="Cursor CLI"
            checksum_blurb="update amd64 and arm64 checksums for the new release"
            ;;
        gcloud-cli)
            updater_rel="scripts/update-gcloud-cli.sh"
            version_arg="GCLOUD_CLI_VERSION"
            display_name="gcloud CLI"
            checksum_blurb="update amd64 and arm64 checksums for the new rapid-channel SDK archive"
            ;;
        kubectl)
            updater_rel="scripts/update-kubectl.sh"
            version_arg="KUBECTL_VERSION"
            display_name="kubectl"
            checksum_blurb="update amd64 and arm64 checksums for the new Kubernetes release"
            ;;
        gke-gcloud-auth-plugin)
            updater_rel="scripts/update-gke-gcloud-auth-plugin.sh"
            version_arg="GKE_GCLOUD_AUTH_PLUGIN_VERSION"
            display_name="gke-gcloud-auth-plugin"
            checksum_blurb="update amd64 and arm64 checksums for the new rapid-channel packager archive"
            ;;
        *)
            usage >&2
            die "unknown package: $1 (expected grok, codex, cursor, gcloud-cli, kubectl, or gke-gcloud-auth-plugin)"
            ;;
    esac
    package="$1"
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

    [[ "$#" -ge 1 && "$#" -le 2 ]] || {
        usage >&2
        die "expected PACKAGE and at most one release argument"
    }

    configure_package "$1"
    local release_arg=""
    if [[ "$#" -eq 2 ]]; then
        release_arg="$2"
    fi

    require_command git
    require_command gh

    local dirty version branch base_branch body_file commit_sha pr_url
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a Git repository"

    [[ -x "${repo_root}/${updater_rel}" ]] || die "missing executable: ./${updater_rel}"
    [[ -f "${repo_root}/dev.Dockerfile" ]] || die "missing dev.Dockerfile"

    dirty="$(dirty_status "$repo_root")"
    if [[ -n "$dirty" ]]; then
        printf '%s\n' "$dirty" >&2
        die "working tree is dirty; commit, stash, or remove changes before running this skill"
    fi

    git -C "$repo_root" fetch origin main

    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/update-software-pr.XXXXXX")"
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

    if [[ -n "$release_arg" ]]; then
        (cd "$worktree" && "./${updater_rel}" "$release_arg")
    else
        (cd "$worktree" && "./${updater_rel}")
    fi

    if git -C "$worktree" diff --quiet -- dev.Dockerfile; then
        printf 'no update detected: dev.Dockerfile is unchanged\n'
        exit 0
    fi

    (cd "$worktree" && single_dockerfile_change_only) || {
        git -C "$worktree" status --short >&2
        die "updater changed files other than dev.Dockerfile"
    }

    version="$(sed -n "s/^ARG ${version_arg}=//p" "${worktree}/dev.Dockerfile" | head -n 1)"
    [[ -n "$version" ]] || die "could not read ${version_arg} from dev.Dockerfile"

    base_branch="update-${package}-$(sanitize_branch_component "$version")"
    branch="$base_branch"
    if (cd "$worktree" && branch_exists "$branch"); then
        branch="${base_branch}-$(date -u +%Y%m%d%H%M%S)"
    fi

    git -C "$worktree" switch -c "$branch"
    git -C "$worktree" add dev.Dockerfile
    git -C "$worktree" commit -m "Update ${display_name} to ${version}"
    git -C "$worktree" push -u origin "$branch"

    cat > "$body_file" <<EOF
## Summary
- update ${display_name} to ${version} in the dev image
- ${checksum_blurb}

## Tests
- ./${updater_rel}${release_arg:+ ${release_arg}}
EOF

    pr_url="$(git -C "$worktree" rev-parse --show-toplevel >/dev/null && cd "$worktree" && gh pr create --base main --head "$branch" --title "Update ${display_name} to ${version}" --body-file "$body_file")"
    commit_sha="$(git -C "$worktree" rev-parse --short HEAD)"

    printf 'branch: %s\n' "$branch"
    printf 'commit: %s\n' "$commit_sha"
    printf 'pr: %s\n' "$pr_url"
}

main "$@"
