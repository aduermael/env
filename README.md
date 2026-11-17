# env

Development environment bootstrap files and the command contract for the
prebuilt `devenv` CLI.

The intended macOS user experience is that a machine with Docker Desktop, but
without Go, can use the prebuilt `devenv` binary from this checkout and run one
setup command:

```sh
devenv setup
```

After setup, a new zsh session should have these commands:

```sh
dev
dev up
dev --tunnel
dev up --tunnel
dev up --tunnel=false
dev down
dev down --all
```

`dev up` (or plain `dev`) starts the dev container for the current git
worktree and registers it as a Herdr machine, in the Herdr app, the herdr TUI,
or both, depending on which are installed. Work happens in Herdr panes on that
machine. Flags after `dev` or `dev up` are passed through, so `dev --tunnel`
and `dev up --tunnel` enable the public tunnel, and `dev up --tunnel=false`
suspends it. `dev down` (the same as `devenv down`) removes that worktree's
container. `dev down --all` (the same as `devenv down --all`) removes every
managed container. Other `down` flags are passed through the same way.

## Build the CLI

### Initial setup

Normal setup can use a prebuilt macOS `devenv` binary. To build it from this
checkout while developing:

```sh
mkdir -p bin
go build -o bin/devenv ./cmd/devenv
```

Then run setup from the checkout:

```sh
./bin/devenv setup --source "$PWD"
```

`devenv setup` copies the running binary to `~/.devenv/bin/devenv` and adds that
directory to the generated zsh block, so future shells use the installed copy.
It cannot update the already-running parent shell. Existing terminals need:

```sh
source ~/.zshrc
```

### Update to a new version

After getting the new revision of the codebase:

```sh
scripts/update-devenv-from-source.sh
```

### Update Codex in the dev image

Codex is pinned in `dev.Dockerfile` with checksums for both Linux image
architectures. The checksums cover the full `codex-package-*` archive
(CLI, code-mode host, `rg`, and `bwrap`). To update it to the latest
upstream release:

```sh
scripts/update-codex.sh
```

To pin a specific release instead:

```sh
scripts/update-codex.sh 0.141.0
```

### Update Grok Build in the dev image

Grok Build is pinned in `dev.Dockerfile` with checksums for both Linux image
architectures. To update it to the latest NPM `alpha` release:

```sh
scripts/update-grok.sh
```

To pin a specific release instead:

```sh
scripts/update-grok.sh 0.2.82
```

### Update Cursor CLI in the dev image

Cursor CLI is pinned in `dev.Dockerfile` with checksums for both Linux image
architectures. To update it to the latest release exposed by Cursor's official
installer:

```sh
scripts/update-cursor.sh
```

To pin a specific release instead:

```sh
scripts/update-cursor.sh 2026.07.16-899851b
```

### Update Google Cloud CLI in the dev image

Google Cloud CLI is pinned in `dev.Dockerfile` with checksums for both Linux
image architectures. The pin is a versioned rapid-channel SDK archive (core CLI
plus default bundled components). The image then installs
`gke-gcloud-auth-plugin` with `gcloud components install` so kubectl can
authenticate to GKE. To update gcloud to the latest rapid-channel release:

```sh
scripts/update-gcloud-cli.sh
```

To pin a specific release instead:

```sh
scripts/update-gcloud-cli.sh 581.0.0
```

### Update kubectl in the dev image

kubectl is pinned in `dev.Dockerfile` with checksums for both Linux image
architectures. To update it to the latest Kubernetes `stable.txt` release:

```sh
scripts/update-kubectl.sh
```

To pin a specific release instead:

```sh
scripts/update-kubectl.sh v1.37.0
```

### Update Dagger CLI in the dev image

Dagger CLI is pinned in `dev.Dockerfile` with checksums for both Linux image
architectures. To update it to the latest Dagger release:

```sh
scripts/update-dagger.sh
```

To pin a specific release instead:

```sh
scripts/update-dagger.sh v0.21.9
```

### Update Claude Code CLI in the dev image

Claude Code CLI is pinned in `dev.Dockerfile` as the npm package
`@anthropic-ai/claude-code`. The image installs that exact version and fails
the build unless `claude --version` contains the pin. To update it to the
latest npm `latest` release:

```sh
scripts/update-claude.sh
```

To pin a specific release instead:

```sh
scripts/update-claude.sh 2.1.238
```

### Update Playwright browser dependencies in the dev image

The image runs `playwright install-deps chromium webkit` at the npm
`playwright` version pinned in `dev.Dockerfile`, so the Chromium and WebKit
system libraries match that release. The browsers themselves are not in the
image; they stay in the `~/.cache/ms-playwright` shared from the host. To
update the pin to the latest npm `latest` release:

```sh
scripts/update-playwright.sh
```

To pin a specific release instead:

```sh
scripts/update-playwright.sh 1.58.2
```

### Update GitHub CLI in the dev image

GitHub CLI (`gh`) is pinned in `dev.Dockerfile` with checksums for both Linux
image architectures. To update it to the latest stable release:

```sh
scripts/update-gh.sh
```

To pin a specific release instead:

```sh
scripts/update-gh.sh 2.98.0
```

### Update herdr in the dev image

herdr is pinned in `dev.Dockerfile` with checksums for both Linux image
architectures. To update it to the latest stable release published at
herdr.dev:

```sh
scripts/update-herdr.sh
```

To pin a specific release instead:

```sh
scripts/update-herdr.sh 0.9.5
```

### Update herdr-core in the dev image

herdr-core (`hc`), the server the Herdr desktop app talks to, is pinned in
`dev.Dockerfile` with checksums from the release manifest at
releases.herdr.dev. To update it to the newest release:

```sh
scripts/update-herdr-core.sh
```

To pin a specific release instead:

```sh
scripts/update-herdr-core.sh 0.1.17
```

## CLI Reference

```sh
devenv setup [flags]
devenv up [flags]
devenv stop [flags]
devenv tunnel configure|status|retire [flags]
devenv down [--all] [flags]
```

`devenv setup` builds the local dev image, prepares `~/.devenv`, starts the safe
Docker proxy, verifies it, and installs shell commands in zshrc. After updating
zshrc it prints:

```text
✅ dev env is ready
⚠️ existing terminals need: source ~/.zshrc
```

Useful setup flags:

- `--source path`: directory containing `dev.Dockerfile`.
- `--image tag`: local dev image tag, default `local-dev:latest`.
- `--root path`: state directory, default `~/.devenv`.
- `--zshrc path`: zshrc file to update, default `~/.zshrc`.
- `--skip-build`: skip rebuilding the Docker image.

`devenv up` starts the detached dev container for the git worktree that
contains the current directory, waits until it answers SSH, saves it as a
Herdr machine, and returns. It does not open a shell and does not run a
command: the container is a Herdr machine, and shells and agents are Herdr
panes on it. Outside a git worktree it fails. The generated `dev up` calls
`devenv up` and appends any flags you passed. Status lines print while the
container starts in the background. Pass `--quiet` when those lines should
stay hidden. Lines that name a command to run are printed regardless.

`devenv stop` and `devenv down` remove the current worktree's container and
stop its tunnel container, retaining its Cloudflare allocation and URLs. The
generated `dev down` calls `devenv down` and appends any flags you passed.
With no container running it succeeds. Outside a git worktree it fails.

`devenv down --all` removes every managed runtime container, including the proxy
bridge and proxy network. It keeps `~/.devenv` state unless `--delete-data` is
passed. `dev down --all` is `devenv down --all`.

`devenv run` no longer exists.

## `devenv setup`

`devenv setup` is the single idempotent bootstrap command. It should be safe to
run repeatedly on the same machine.

The command must:

- Build the dev Docker image locally from `dev.Dockerfile`. Users should not
  need Go, but they do need this repository checkout so Docker can build the
  image in place.
- Create the host state directory at `~/.devenv` if it does not exist.
- Install the current `devenv` binary at `~/.devenv/bin/devenv` so generated
  shell functions have a stable command to call.
- Initialize env-owned Git config and SSH identity files only when they are
  missing.
- Install or update the generated zshrc block that defines `dev`.
- Start or repair the safe Docker socket proxy, then verify the proxy container
  is running and the proxied socket is usable.

`setup` must not overwrite existing identity or persisted tool state. Existing
`~/.devenv/gitconfig`, SSH keys, and `~/.devenv/home` contents are user state.
The command may update generated shell functions inside its own marker block,
but it must preserve user edits outside that block.

## Generated zshrc Block

`devenv setup` should install one generated block in the user's zshrc. Re-running
setup should replace this block in place, not append duplicates.

The user-facing command contract is:

```sh
# >>> devenv >>>
export DEVENV_HOME="${DEVENV_HOME:-$HOME/.devenv}"
export DEVENV_IMAGE="${DEVENV_IMAGE:-local-dev:latest}"
export DEVENV_SOURCE="${DEVENV_SOURCE:-/path/to/env}"
export DEVENV_PROXY_PORT="${DEVENV_PROXY_PORT:-23750}"
case ":$PATH:" in
  *":$DEVENV_HOME/bin:"*) ;;
  *) export PATH="$DEVENV_HOME/bin:$PATH" ;;
esac

dev() {
  local cmd=up
  if [ $# -gt 0 ]; then
    case "$1" in
      -*) ;;
      up|down) cmd=$1; shift ;;
      *)
        echo "usage: dev [up] [flags] | dev down [flags]" >&2
        return 2
        ;;
    esac
  fi
  command devenv "$cmd" "$@"
}
# <<< devenv <<<
```

`dev` with no arguments is `dev up`. Flags are forwarded as given: `dev --tunnel`
is `devenv up --tunnel`, and `dev --quiet` is `devenv up --quiet`. `dev down`
stops the current worktree. `dev down --all` stops every managed container.
Any command name other than `up` or `down` prints usage and does not start or
stop a container.

## Herdr machines

Each git worktree has at most one dev container, and that container is a
saved Herdr machine. `dev up` from anywhere inside a worktree starts it. The
same worktree keeps the same machine the next time `dev up` starts it: the
SSH alias `devenv-<id>`, the loopback port, the host key, and the remote
session `default` are fixed per worktree and stored in
`~/.devenv/herdr/worktrees.json`.

- The machine id is `<repo>-<worktree>-<6 random chars>`, for example
  `env-root-a1b2c3` for the main checkout or `env-feature-c4d5e6` for
  `<repo>/worktrees/feature`. The Docker container and the SSH alias are
  `devenv-<id>`.
- The repository root (the parent of the main `.git`) is mounted at
  `/workspace` and, when the path differs, at the same absolute path it has on
  the Mac. Herdr panes start at `/workspace` for the main checkout and at
  `/workspace/worktrees/<name>` for a linked worktree.
- Linked worktrees must live at `<repo>/worktrees/<name>`. `dev up` elsewhere
  fails and names that directory. Add `worktrees/` to `.git/info/exclude` so
  the main checkout does not list them as untracked.
- A submodule checkout uses the enclosing worktree's machine.
- `sshd` is the container's main process. Closing the Herdr client leaves the
  server and its panes running. `dev down` removes the container; the Herdr
  profile, SSH alias, registry row, host key, and Herdr volume stay, and the
  next `dev up` brings the same machine back.
- `dev up` registers the container with each Herdr client the Mac has: the
  herdr TUI (`herdr` on `PATH`), the Herdr desktop app (`hc`, see below), or
  both. Having only one of them is fine; the other is skipped. When neither is
  installed, `dev up` still succeeds and prints both `machine add` lines to
  run later.
- The container is also a machine for the Herdr desktop app. The image ships
  `hc` (herdr-core), and `dev up` runs `hc machine add devenv-<id> --name
  <id>` when the Mac has `hc` on `PATH` or at `~/.local/bin/hc`. The
  entrypoint starts the container's core from the worktree directory, which
  is where the app opens new terminals on that machine, and restarts it when
  it dies. The TUI and the app do not share terminals: a pane in one is not
  visible in the other, but both run in the same container.
- The container's core has an identity that lives on the per-worktree volume.
  If that volume is removed, the app reports the machine as "a different core
  answers there", and the next `dev up` replaces the entry.
- `dev up` warns when the Mac's `hc` version differs from the container's.
  Bump the pin with `scripts/update-herdr-core.sh` and rebuild, then `dev
  down` and `dev up`. `hc machine update <id>` copies the Mac's `hc` into the
  shared home instead; it works in a pinch, but the next image bump makes that
  copy stale, so prefer the pin.
- Rebuilding the image with `devenv setup` does not restart a running
  workspace container. The new image is used after `dev down` and `dev up`.
- `devenv down --all --delete-data` removes the keys, the registry, the Herdr
  volumes, and the managed include in `~/.ssh/config`. Saved Herdr profiles
  then point at nothing; remove them with `herdr machine remove <id>` after
  reading `herdr machine list`.

## Host State Layout

The CLI should use an actual host folder, not an anonymous or named Docker home
volume. The default layout is:

```text
~/.devenv/
  bin/
    devenv
  gitconfig
  home/
    .codex/
  ssh/
    id_ed25519
    id_ed25519.pub
  herdr/
    ssh_host_ed25519_key
    ssh_host_ed25519_key.pub
    id_ed25519.pub
    worktrees.json
    worktrees.lock
    ssh_config
    known_hosts
  run/
    docker.sock
    proxy-bridge.pid
```

The Herdr client private key is `~/.ssh/devenv_herdr_ed25519`, outside
`~/.devenv`, because `~/.devenv` is mounted into every container. Only its
public half is copied to `~/.devenv/herdr/id_ed25519.pub`. `~/.ssh/config`
gets a managed include block at the top that points at
`~/.devenv/herdr/ssh_config`, where each worktree's `devenv-<id>` alias is
rendered.

Mount contract:

- `~/.devenv/home` is mounted as `/home/dev` so tool state such as `~/.codex`
  persists across containers. Codex SQLite (logs, memories, thread index) is
  stored on a Linux Docker volume at `/var/lib/codex-sqlite` instead of that
  bind mount. A multi-gigabyte `logs_2.sqlite` on macOS virtiofs can stall TUI
  startup on "loading" the model for a long time.
- `~/.devenv` is mounted read-only at `/devenv`, and containers receive
  `GIT_CONFIG_GLOBAL=/devenv/gitconfig` so env-owned Git config is used without
  overlaying files inside the persisted home bind mount.
- `~/.devenv/ssh` contains the env-specific SSH keypair and is mounted as
  `/home/dev/.ssh`.
- `~/.devenv/run/docker.sock` is the safe proxied Docker socket used for host
  health checks and host-side Docker CLI access.
- Dev containers join the managed proxy Docker network and receive
  `DOCKER_HOST=tcp://devenv-dockerproxy:2375`, avoiding direct host Docker
  socket mounts.
- The repository root of the current git worktree is mounted at `/workspace`.
- `~/.devenv/home/.config/herdr`, `~/.devenv/home/.local/state/herdr`, and
  `~/.devenv/home/.local/state/herdr-core` are symlinks onto the per-worktree
  Herdr volume (`devenv-herdr-<id>`, mounted at `/var/lib/devenv/herdr`).
  Herdr config, sockets, session state, and logs, and the herdr-core identity,
  state, and socket, are per worktree. Other tool config under `~/.config`,
  such as `gh` and `herdr-core`, stays shared. `XDG_CONFIG_HOME` and
  `XDG_STATE_HOME` are never set.

`~/.devenv/gitconfig` should include:

```ini
[worktree]
    useRelativePaths = true
```

The SSH private key must be created with restrictive permissions, for example
`0600`, and setup must never replace it after creation. Users can add the public
key at `~/.devenv/ssh/id_ed25519.pub` to GitHub or another Git host.

## GitHub CLI (`gh`)

Run GitHub CLI commands in a Herdr pane on the worktree's machine after
`dev up`. To authenticate with GitHub, run this in a pane:

```sh
gh auth login --hostname github.com --git-protocol ssh --web
```

`gh` keeps its state in the shared `~/.devenv/home/.config/gh`, so one login
covers every worktree.

Follow the instructions printed by `gh`. If your env SSH key is already uploaded
on GitHub, skip the SSH key upload step.

## Safe Docker Socket

Dev containers should not bind mount the host Docker socket directly. The CLI
runs a Docker socket proxy container that binds the real host socket read-only
and exposes a filtered Docker API on a managed Docker network. A small
`devenv` bridge process exposes the same filtered API as a host Unix socket at
`~/.devenv/run/docker.sock` so setup can verify it and host-side tools can use
it with `DOCKER_HOST=unix://$HOME/.devenv/run/docker.sock`.

`devenv setup` should create or reuse the proxy container and bridge, recreate
them when configuration is stale or unhealthy, and wait until the proxied socket
and proxy network are usable before reporting success.

The safe socket proxy is runtime infrastructure. Repairing or recreating it must
not remove `~/.devenv/home`, `~/.devenv/gitconfig`, or SSH keys.

## `devenv down`

`devenv down` removes the current git worktree's container and stops its tunnel
container. The proxy, other worktrees, the Herdr profile, the SSH alias, the
registry row, the host key, and the Herdr volume stay. With no container
running it succeeds. Outside a git worktree it fails. `devenv stop` does the
same thing.

`devenv down --all` tears down every running container managed by the CLI for
this root, including the safe Docker socket proxy and every worktree. It is
also idempotent: running it when no managed containers exist should succeed.

`devenv down --all` must not delete identity or durable state:

- Do not delete `~/.devenv/gitconfig`.
- Do not delete `~/.devenv/home` or tool state such as `~/.codex`.
- Do not remove the Codex SQLite Docker volume unless `--delete-data` is passed.
- Do not delete `~/.devenv/ssh` or its keypair.
- Do not delete `~/.devenv/herdr`: the host key, the worktree registry, and
  the rendered SSH config are what keep each worktree on the same Herdr
  machine. Do not remove the managed include in `~/.ssh/config`.
- Do not remove the per-worktree Herdr volumes or saved Herdr profiles. Saved
  machines, in the TUI and in the desktop app, go offline and come back on
  the next `dev up`. The volume also holds the herdr-core identity the app
  pins; removing it makes the app's entry unusable until `dev up` replaces it.
- Do not remove the generated zshrc block.
- Do not remove the dev image unless a separate explicit prune command or flag
  is added.

`devenv down --all --delete-data` is the only command that removes `~/.devenv`,
the Herdr volumes, and the include block. `--delete-data` without `--all` is
an error.

The next `devenv setup` or launcher command should be able to recreate runtime
containers without forcing the user to re-authenticate tools.

## Image Contents

The dev image includes Go, Rust, Node 24, Python with pip/venv, Lua, Luau,
Codex CLI, Claude Code CLI, Gemini CLI, Grok Build CLI, Cursor CLI, Homebrew,
Git 2.55.0, Git LFS, OpenSSH client and server, tini, GitHub CLI (`gh`), herdr, herdr-core (`hc`), Google Cloud CLI (`gcloud`),
kubectl, Dagger CLI (`dagger`), `gke-gcloud-auth-plugin`, Modal CLI, Blender CLI, `ping`, jq,
ripgrep (`rg`), `tree`, GNU `time` (`/usr/bin/time`), `less`, `pkg-config`, zip/unzip, pnpm, Bazelisk with
Bazel 9.2.0 pre-cached, PostgreSQL, ffmpeg, ImageMagick, pandoc, WeasyPrint,
bash, build tools, common dev headers, and the Docker CLI with the Compose
plugin.

GNU `time` is `/usr/bin/time` so it does not replace the shell builtin. To
report wall time, CPU, and peak memory for a command:

```sh
/usr/bin/time -v command
```

Every assistant CLI in this image defaults to its allow-all mode because the
container is the isolation boundary: Codex runs without its own sandbox and with
`approval_policy = "never"` (`/etc/codex/config.toml`), Grok Build uses
`permission_mode = "always-approve"` (`/etc/grok/managed_config.toml`), Claude
Code gets `permissions.defaultMode = "bypassPermissions"` (with the bypass
dialog pre-accepted) seeded into `~/.claude/settings.json` when unset, and `gemini` / `agent` / `cursor-agent`
are wrappers in `/usr/local/lib/agent-defaults/bin` that add
`--approval-mode=yolo` / `--yolo` unless a mode flag is passed. User config
still wins for Codex, Grok and Claude Code. Do not mount sensitive host paths
into containers where these agents run with broad autonomy. Use the safe Docker
socket proxy if Docker CLI access is needed.

Codex is installed from `codex-package-*` at
`/usr/local/lib/codex/<version>-<target>`. `/usr/local/bin/codex` points at
`bin/codex` inside that package so the CLI can find `codex-package.json`,
`codex-path/rg`, and `codex-resources/bwrap`. `codex-code-mode-host` ships in
the same package, at `/usr/local/bin/codex-code-mode-host` and
`/usr/local/libexec/codex-code-mode-host`.

Codex SQLite state uses `CODEX_SQLITE_HOME=/var/lib/codex-sqlite`. Leave that on
a Linux volume, not the macOS `~/.devenv/home` bind mount. Codex writes TRACE
payloads into `logs_2.sqlite`; on a bind mount that file can grow to many
gigabytes and block model catalog / TUI startup. The container entrypoint moves
`logs_2.sqlite` aside when it is larger than 1 GiB. Stale `*.stale-*` files in
`~/.codex` can be deleted to reclaim disk.

Codex enhanced keyboard reporting follows Codex's default behavior. To force the
legacy Docker TTY behavior, set `CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT=1`
before launching the container.

PostgreSQL is installed but not started automatically. Start the packaged
cluster inside the container with:

```sh
sudo pg_ctlcluster 15 main start
```

The image includes Blender CLI as `blender`. Use background mode for headless
work:

```sh
blender -b --python-expr "import bpy; print(bpy.app.version_string)"
blender -b scene.blend --python script.py
```

On x86_64 this is the official Blender 5.2.1 Linux tarball. Upstream does not
publish a Linux arm64 build, so arm64 images use an unofficial portable 5.1.0
build from [lfdevs/blender-linux-arm64](https://github.com/lfdevs/blender-linux-arm64)
(Rocky Linux 8 / glibc 2.28, matching official Linux portability).

## Git Worktrees

If you use Git worktrees from both the host and this container, use Git 2.48.0
or newer everywhere that will touch the repository. This image builds Git 2.55.0.

Enable relative worktree links before creating worktrees:

```sh
git config --global worktree.useRelativePaths true
```

Linked worktrees must live at `<repo>/worktrees/<name>`:

```sh
git worktree add worktrees/feature -b feature
cd worktrees/feature
dev up
```

The container sees the repository root at `/workspace` and, when the path
differs, at the same absolute path it has on the Mac. One mount covers `.git`,
the main checkout, and every `worktrees/<name>` checkout, so both relative and
absolute worktree links resolve inside the container. Relative links are still
preferred: they keep the worktrees usable as long as the repository and its
worktree directories move together.

Existing absolute-path worktrees should be recreated or repaired with Git 2.48.0
or newer:

```sh
git worktree repair --relative-paths
```

Relative worktree links enable Git's `extensions.relativeWorktrees` repository
extension, so older Git versions will reject those repositories.

## Manual Image Build

`devenv setup` performs this build automatically. To rebuild manually:

```sh
docker build -f dev.Dockerfile -t local-dev:latest .
```

## Optional public worktree URLs

Public ingress is **off by default**. The host CLI owns Cloudflare allocation and
automatically runs `cloudflare/cloudflared:2026.11.0` in a separate Docker container
for each enabled worktree. Docker pulls the image as needed; no host `cloudflared`
installation is required. Use a local Docker Desktop Unix-socket context so Docker
can mount the private host runtime-token file into the tunnel container.

Create a Cloudflare API token restricted to the development account with
Cloudflare Tunnel edit access and the development zone with DNS edit and zone
read access. Store it in a mode-600 file outside both the env state root
(`~/.devenv` by default) and every repository mounted into a workspace. Do not put
it in this checkout. Configure the host once:

```sh
devenv tunnel configure \
  --account-id YOUR_ACCOUNT_ID \
  --zone-id YOUR_ZONE_ID \
  --domain ok-houston.dev \
  --api-token-file "$HOME/.config/devenv-secrets/cloudflare-api-token" \
  --origin http://houston:80
```

The domain must exactly match the Cloudflare zone. The origin is one HTTP Docker
network alias and explicit port. For a server running directly inside the
workspace, omit `--origin` to use `http://workspace:8080`. Houston instead attaches
its sibling proxy as `houston` on the provided ingress network.

Both the main repository checkout and linked worktrees are supported, regardless
of the checked-out branch. From the desired Git checkout on the **host**:

```sh
devenv up --tunnel
devenv tunnel status
```

The Cloudflare-assigned random tunnel UUID becomes the deployment identity:
`https://UUID.ok-houston.dev` and `https://files-UUID.ok-houston.dev`. There is one
allocation per canonical worktree Git directory; duplicate human-readable tree
names do not collide. Plain `devenv up` reuses the enabled allocation and URLs.
Stop a workspace before enabling or disabling ingress, or moving its checkout.
Moving a stopped linked worktree while retaining its Git directory preserves the
binding. Moving the repository's Git directory changes that identity; stop and
retire the old allocation before such a move.

The workspace receives exactly these ingress settings:

| Setting | Value |
| --- | --- |
| `DEVENV_INSTANCE_ID` | Canonical tunnel UUID |
| `DEVENV_PUBLIC_URL` | HTTPS application origin |
| `DEVENV_FILES_URL` | HTTPS file origin |
| `DEVENV_INGRESS_NETWORK` | `devenv-ingress-UUID` |

The external bridge network has label `io.devenv.instance=UUID`. Each allocation
has its own network. Its tunnel container routes the two exact public hosts
directly to the configured origin, preserving the HTTP Host header. For a service
inside the workspace, bind to `0.0.0.0:8080` so the sidecar can reach it through
Docker DNS as `workspace:8080`. All other tunnel hosts return 404. There are no
published host ports and no intermediate relay.

The account API token stays on the host. Only the per-tunnel runtime token is
mounted read-only into the tunnel container, which runs with a read-only root
filesystem and dropped capabilities. Neither credential is passed in container
environment variables or command arguments, or mounted into the workspace.

The workspace retains full Docker capabilities for builds and Dagger. An agent
with that access can inspect sibling containers and reach their credentials.
The sidecar keeps secrets out of workspace files and environment, but does not
provide isolation against Docker API access. Separating the engines is a future
improvement; use a dedicated development account and zone.

```sh
devenv stop                 # Stop this workspace and tunnel container; retain URLs.
devenv up                   # Restart the same enabled allocation.
devenv stop
devenv up --tunnel=false    # Run privately; retain the allocation for later reuse.
devenv tunnel retire        # Stop ingress and delete only its owned DNS/tunnel.
```

After retirement, stop any remaining workspace and explicitly run
`devenv up --tunnel` to allocate new URLs. Plain `up` remains private. Retirement
refuses DNS records that were reassigned. Interrupted provisioning and retirement
can be retried; keep the private state so retries recover the original allocation.
The configured origin is a default for new allocations. Existing allocations keep
their stored origin across restarts, so changing the default for another project
does not retarget them. Retire and explicitly allocate again to change an origin.
Existing bindings retain their account, zone, and domain; restore the original
host settings or retire before changing those properties.

Host settings, runtime tokens, and allocation records live outside workspace
mounts under `~/Library/Application Support/devenv-tunnels` on macOS. Set
`DEVENV_TUNNEL_HOME` consistently to choose another private host directory. Paths
are checked after resolving symlinks. `devenv down` and `devenv down --all`,
including `--delete-data`, retain this directory and Cloudflare allocations.
Keep it when clearing workspace data; use `tunnel retire` for intentional
remote cleanup. Container ownership
labels are checked before reusing or removing a tunnel container. Docker manages
its restart policy and logs; `devenv tunnel status` prints its name for
`docker logs NAME`. Stop an existing native tunnel with the previous CLI version
before upgrading to this sidecar version.

### First test: JSON over public HTTPS

This test only needs the env branch, Docker Desktop and your development
Cloudflare account/zone. Houston and houston-hub do not need to be merged or run.
Use this env checkout, or any Git checkout without an existing tunnel allocation;
no second worktree is required. If it already has a tunnel with a different
origin, retire that allocation first or use another existing checkout.

On your Mac, stop any running environment for the test checkout with the currently
installed `devenv stop`, then install the branch's prebuilt macOS ARM64 CLI:

```sh
git switch feat/worktree-tunnels
git pull --ff-only
git lfs pull
./bin/devenv setup --source "$PWD"
source ~/.zshrc
```

Allow setup to rebuild the workspace image so public metadata reaches new Herdr
sessions. Put the restricted account API token in
`~/.config/devenv-secrets/cloudflare-api-token`, outside all workspace mounts,
then configure and start from your test checkout **on the Mac**:

```sh
chmod 600 "$HOME/.config/devenv-secrets/cloudflare-api-token"
devenv tunnel configure \
  --account-id YOUR_ACCOUNT_ID \
  --zone-id YOUR_ZONE_ID \
  --domain YOUR_ZONE_DOMAIN \
  --api-token-file "$HOME/.config/devenv-secrets/cloudflare-api-token" \
  --origin http://workspace:8080
devenv up --tunnel
devenv tunnel status
```

Open the new workspace machine in Herdr. **Inside the container**, start a server:

```sh
cat > /tmp/tunnel-smoke.go <<'EOF'
package main

import (
    "fmt"
    "log"
    "net/http"
    "os"
)

func main() {
    http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Content-Type", "application/json")
        w.Header().Set("Cache-Control", "no-store")
        fmt.Fprintln(w, `{"ok":true}`)
    })
    log.Printf("Public URL: %s", os.Getenv("DEVENV_PUBLIC_URL"))
    log.Fatal(http.ListenAndServe("0.0.0.0:8080", nil))
}
EOF
go run /tmp/tunnel-smoke.go
```

Leave that server running. In another **Mac terminal**, use the `App` URL from
`devenv tunnel status`:

```sh
curl -i https://UUID.YOUR_ZONE_DOMAIN/
```

Expect HTTP 200 and `{"ok":true}`. Initial DNS/certificate activation can take
time. For a 502, first check `curl -i http://localhost:8080/` inside the workspace
and confirm that `Origin` in the status output is `http://workspace:8080`. On the
Mac, `docker logs devenv-tunnel-UUID` shows the connector's connection status.

Run `devenv stop` on the Mac to stop both containers and keep the URL for later.
`devenv tunnel retire` additionally deletes this allocation's DNS records and
Cloudflare tunnel. Neither command needs Houston.

Validate the CLI with `go test ./...` and `go vet ./...`. The opt-in
`DEVENV_TEST_DOCKER=1 go test ./cmd/devenv -run '^TestTunnelDockerNetwork$' -v`
exercises Docker DNS, app/file Host routing, restart and container ownership using
a static HTTP probe in the real cloudflared image. It creates and cleans up
isolated fixture containers and a network without Cloudflare credentials. The
normal tests cover allocation, direct ingress configuration and sidecar lifecycle.
Live public HTTPS and Docker Desktop token-mount acceptance still require a
configured macOS host.
Where a local SSH daemon can run, `DEVENV_TEST_SSH=1 go test ./cmd/devenv -run
'^TestTunnelMetadataThroughSSHSession$' -v` verifies that public metadata reaches
an actual SSH session. It uses temporary keys and configuration without modifying
host SSH setup; the normal suite always checks the entrypoint environment lists.

The tracked `bin/devenv` executable targets macOS ARM64 (Git LFS); the root
`devenv` artifact targets Linux ARM64. Rebuild both after CLI source changes:

```sh
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -o bin/devenv ./cmd/devenv
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -o devenv ./cmd/devenv
```

Run `devenv setup` using the new binary to update the installed host copy.
