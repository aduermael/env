#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
devenv_bin="${repo_root}/bin/devenv"

usage() {
    cat <<'EOF'
Usage: scripts/update-devenv-from-source.sh

Rebuilds the local devenv binary from this checkout and runs setup with the
checkout as the source.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    if [[ "$#" -ne 0 ]]; then
        usage
        die "expected no arguments"
    fi

    require_command go

    mkdir -p "${repo_root}/bin"

    printf 'remove: %s\n' "$devenv_bin"
    rm -f "$devenv_bin"

    printf 'build: %s\n' "$devenv_bin"
    (
        cd "$repo_root"
        go build -o ./bin/devenv ./cmd/devenv
    )

    printf 'setup: %s setup --source %s\n' "$devenv_bin" "$repo_root"
    "$devenv_bin" setup --source "$repo_root"
}

main "$@"
