#!/usr/bin/env bash
# Drives the shipped Claude Code updater against a fixture copy of dev.Dockerfile.
# An explicit version rewrites only CLAUDE_CODE_VERSION and does not contact a registry.
# latest and a bare invocation resolve the version from a local npm dist-tag fixture.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="${repo_root}/dev.Dockerfile"
update_script="${repo_root}/scripts/update-claude.sh"
pr_runner="${repo_root}/.codex/skills/update-software/scripts/update-software-pr.sh"
tmpdir=""
server_pid=""

die() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "${server_pid}" ]]; then
        kill "${server_pid}" >/dev/null 2>&1 || true
        wait "${server_pid}" >/dev/null 2>&1 || true
    fi
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
    local file="$2"
    local line
    line="$(grep -E "^ARG ${name}=" "$file" || true)"
    [[ -n "$line" ]] || die "missing ARG ${name}= in ${file}"
    printf '%s\n' "${line#ARG ${name}=}"
}

other_lines() {
    grep -v '^ARG CLAUDE_CODE_VERSION=' "$1"
}

require_command grep
require_command awk
require_command mktemp
require_command bash
require_command python3
require_command curl

[[ -f "$dockerfile" ]] || die "Dockerfile not found: $dockerfile"
[[ -f "$update_script" ]] || die "update script not found: $update_script"
[[ -x "$update_script" ]] || die "update script is not executable: $update_script"
[[ -f "$pr_runner" ]] || die "PR runner not found: $pr_runner"

bash -n "$update_script" || die "bash -n failed for update-claude.sh"
bash -n "$pr_runner" || die "bash -n failed for update-software-pr.sh"
printf 'ok: bash -n passed for update-claude.sh and update-software-pr.sh\n'

grep -Fq 'pnpm add -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"' "$dockerfile" \
    || die "shipped Dockerfile dropped the Claude Code pnpm install"
grep -Fq 'node "${claude_pkg}/install.cjs"' "$dockerfile" \
    || die "shipped Dockerfile dropped the Claude Code install.cjs step"
grep -Fq 'claude_ver_out="$(claude --version)"' "$dockerfile" \
    || die "shipped Dockerfile dropped the claude --version capture"
grep -Fq 'grep -F "${CLAUDE_CODE_VERSION}"' "$dockerfile" \
    || die "shipped Dockerfile dropped the Claude Code version pin check"
install_count="$(grep -c '@anthropic-ai/claude-code@' "$dockerfile")"
[[ "$install_count" -eq 1 ]] || die "expected one Claude Code install, found ${install_count}"

current="$(arg_value CLAUDE_CODE_VERSION "$dockerfile")"
[[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "CLAUDE_CODE_VERSION must be dotted numeric semver, got: $current"

requested="9.8.7"
if [[ "$current" == "$requested" ]]; then
    requested="9.8.6"
fi

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/test-update-claude.XXXXXX")"
fixture_df="${tmpdir}/dev.Dockerfile"
cp "$dockerfile" "$fixture_df"
before_other="${tmpdir}/before-other.txt"
other_lines "$fixture_df" > "$before_other"

# A refused local port proves the explicit-version path does not query a registry.
if DOCKERFILE="$fixture_df" CLAUDE_NPM_REGISTRY="http://127.0.0.1:1" bash "$update_script" "$requested"; then
    :
else
    die "explicit version update failed"
fi

rewritten="$(arg_value CLAUDE_CODE_VERSION "$fixture_df")"
[[ "$rewritten" == "$requested" ]] || die "ARG CLAUDE_CODE_VERSION=${rewritten}, want ${requested}"
[[ "$rewritten" != "$current" ]] || die "explicit version did not change the pin"
other_lines "$fixture_df" > "${tmpdir}/after-explicit.txt"
diff -u "$before_other" "${tmpdir}/after-explicit.txt" \
    || die "explicit version update changed lines other than CLAUDE_CODE_VERSION"
grep -Fq 'pnpm add -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"' "$fixture_df" \
    || die "pnpm install no longer interpolates CLAUDE_CODE_VERSION"
grep -Fq 'node "${claude_pkg}/install.cjs"' "$fixture_df" \
    || die "install.cjs step disappeared"
grep -Fq 'claude_ver_out="$(claude --version)"' "$fixture_df" \
    || die "claude --version check disappeared"
grep -Fq 'grep -F "${CLAUDE_CODE_VERSION}"' "$fixture_df" \
    || die "version pin check disappeared"
printf 'ok: explicit version %s rewrote only CLAUDE_CODE_VERSION\n' "$requested"
printf 'ARG CLAUDE_CODE_VERSION=%s\n' "$(arg_value CLAUDE_CODE_VERSION "$fixture_df")"
grep -F 'pnpm add -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"' "$fixture_df"
grep -F 'claude_ver_out="$(claude --version)"' "$fixture_df"
grep -F 'grep -F "${CLAUDE_CODE_VERSION}"' "$fixture_df"
printf 'other version ARGs unchanged\n'

cp "$dockerfile" "$fixture_df"
if DOCKERFILE="$fixture_df" CLAUDE_NPM_REGISTRY="http://127.0.0.1:1" bash "$update_script" "not-a-version"; then
    die "invalid version was accepted"
fi
[[ "$(arg_value CLAUDE_CODE_VERSION "$fixture_df")" == "$current" ]] \
    || die "invalid version changed CLAUDE_CODE_VERSION"
printf 'ok: invalid version leaves the pin unchanged\n'

registry_version="3.2.1"
if [[ "$registry_version" == "$current" || "$registry_version" == "$requested" ]]; then
    registry_version="3.2.2"
fi
port_file="${tmpdir}/port"
path_log="${tmpdir}/registry-paths.log"
python3 - "$port_file" "$path_log" "$registry_version" <<'PY' &
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port_file, path_log, version = sys.argv[1], sys.argv[2], sys.argv[3]
expected = "/%40anthropic-ai%2fclaude-code/latest"

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        with open(path_log, "a", encoding="utf-8") as handle:
            handle.write(path + "\n")
        if path != expected:
            self.send_error(404)
            return
        body = json.dumps({"version": version}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return

server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(port_file, "w", encoding="utf-8") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
PY
server_pid="$!"

for _ in $(seq 1 50); do
    [[ -s "$port_file" ]] && break
    sleep 0.1
done
[[ -s "$port_file" ]] || die "local npm registry did not start"
port="$(cat "$port_file")"

run_registry_update() {
    local mode="$1"
    cp "$dockerfile" "$fixture_df"
    if [[ "$mode" == "latest" ]]; then
        DOCKERFILE="$fixture_df" CLAUDE_NPM_REGISTRY="http://127.0.0.1:${port}" bash "$update_script" latest
    else
        DOCKERFILE="$fixture_df" CLAUDE_NPM_REGISTRY="http://127.0.0.1:${port}" bash "$update_script"
    fi
    [[ "$(arg_value CLAUDE_CODE_VERSION "$fixture_df")" == "$registry_version" ]] \
        || die "${mode} resolved $(arg_value CLAUDE_CODE_VERSION "$fixture_df"), want ${registry_version}"
    other_lines "$fixture_df" > "${tmpdir}/after-${mode}.txt"
    diff -u "$before_other" "${tmpdir}/after-${mode}.txt" \
        || die "${mode} update changed lines other than CLAUDE_CODE_VERSION"
    grep -Fq 'pnpm add -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"' "$fixture_df" \
        || die "${mode} update dropped the interpolated pnpm install"
    grep -Fq 'grep -F "${CLAUDE_CODE_VERSION}"' "$fixture_df" \
        || die "${mode} update dropped the version pin check"
    printf 'ok: %s resolved npm dist-tag %s\n' "$mode" "$registry_version"
}

run_registry_update latest
run_registry_update bare

printf 'ALL CHECKS PASSED\n'
