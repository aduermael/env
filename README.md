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
codex
claude
gemini
devenv down
```

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
# from repository root directory

# remove old binary if it exists
rm ./bin/devenv

# build new binary
go build -o ./bin/devenv ./cmd/devenv

# self-install new binary
./bin/devenv setup --source "$PWD"
```

### Update Codex in the dev image

Codex is pinned in `dev.Dockerfile` with checksums for both Linux image
architectures. To update it to the latest upstream release:

```sh
scripts/update-codex.sh
```

To pin a specific release instead:

```sh
scripts/update-codex.sh 0.141.0
```

## CLI Reference

```sh
devenv setup [flags]
devenv run [flags] [--] [command [args...]]
devenv down [flags]
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

`devenv run` starts the dev container in the current directory. With no command,
it opens the image default shell. With a command, it runs that command in the dev
container. The generated zsh commands call `devenv run --quiet`, so normal
preflight checks stay silent unless something fails.

`devenv down` removes managed runtime containers, proxy bridge, and proxy
network. It keeps `~/.devenv` state unless `--delete-data` is passed.

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
- Install or update the generated zshrc block that defines `dev`, `codex`,
  `claude`, and `gemini`.
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
  devenv run --quiet -- "$@"
}

codex() {
  devenv run --quiet -- codex "$@"
}

claude() {
  devenv run --quiet -- claude "$@"
}

gemini() {
  devenv run --quiet -- gemini "$@"
}
# <<< devenv <<<
```

`dev` opens an interactive shell in the dev container with the current directory
mounted at `/workspace`. Arguments passed to `dev` are forwarded to `devenv run`
so callers can run a specific command in the same container environment.

`codex`, `claude`, and `gemini` run the corresponding assistant CLI inside the
dev container and forward all arguments unchanged.

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
  run/
    docker.sock
    proxy-bridge.pid
```

Mount contract:

- `~/.devenv/home` is mounted as `/home/dev` so tool state such as `~/.codex`
  persists across containers.
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
- The current working directory is mounted at `/workspace`.

`~/.devenv/gitconfig` should include:

```ini
[worktree]
    useRelativePaths = true
```

The SSH private key must be created with restrictive permissions, for example
`0600`, and setup must never replace it after creation. Users can add the public
key at `~/.devenv/ssh/id_ed25519.pub` to GitHub or another Git host.

## GitHub CLI (`gh`)

Run GitHub CLI commands through the `dev` launcher from the host. To authenticate
with GitHub:

```sh
dev gh auth login --hostname github.com --git-protocol ssh --web
```

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

`devenv down` tears down running containers managed by the CLI, including the
safe Docker socket proxy. It is also idempotent: running it when no managed
containers exist should succeed.

`devenv down` must not delete identity or durable state:

- Do not delete `~/.devenv/gitconfig`.
- Do not delete `~/.devenv/home` or tool state such as `~/.codex`.
- Do not delete `~/.devenv/ssh` or its keypair.
- Do not remove the generated zshrc block.
- Do not remove the dev image unless a separate explicit prune command or flag
  is added.

The next `devenv setup` or launcher command should be able to recreate runtime
containers without forcing the user to re-authenticate tools.

## Image Contents

The dev image includes Go, Rust, Node 24, Python with pip/venv, Lua, Luau,
Codex CLI, Claude Code CLI, Gemini CLI, Homebrew, Git 2.54.0, Git LFS, OpenSSH
client, GitHub CLI (`gh`), Modal CLI, `ping`, jq, ripgrep (`rg`), `tree`,
`less`, `pkg-config`, zip/unzip, pnpm, PostgreSQL, ffmpeg, ImageMagick, pandoc,
WeasyPrint, bash, build tools, common dev headers, and the Docker CLI with the
Compose plugin.

Codex is configured to run without its own sandbox inside this image because the
container is the isolation boundary. Do not mount sensitive host paths into
containers where Codex runs with broad autonomy. Use the safe Docker socket proxy
if Docker CLI access is needed.

Codex enhanced keyboard reporting follows Codex's default behavior. To force the
legacy Docker TTY behavior, set `CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT=1`
before launching the container.

PostgreSQL is installed but not started automatically. Start the packaged
cluster inside the container with:

```sh
sudo pg_ctlcluster 15 main start
```

## Git Worktrees

If you use Git worktrees from both the host and this container, use Git 2.48.0
or newer everywhere that will touch the repository. This image builds Git 2.54.0.

Enable relative worktree links before creating worktrees:

```sh
git config --global worktree.useRelativePaths true
```

The container sees the checkout at `/workspace`, while the host usually sees the
same files at a different absolute path. Git worktrees store links between the
main checkout and linked worktrees, so absolute links written in one environment
may not exist in the other. Relative links keep the worktrees usable as long as
the repository and its worktree directories move together.

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
