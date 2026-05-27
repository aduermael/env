# env
Environment setup files

## Local Dev Container

If you use Git worktrees, configure them to store relative paths so the same
worktree metadata works both with host-side Git auth and inside dev containers:

```sh
git config --global worktree.useRelativePaths true
```

When `~/.gitconfig` is mounted into a dev container, the container inherits this
setting.

Build the local development image:

```sh
docker build -f dev.Dockerfile -t local-dev:latest .
```

Run it with the default container user, `dev:1000`:

```sh
docker run --rm -it \
  -v "$PWD:/workspace" \
  local-dev:latest
```

Run it with a user that matches your host UID, GID, and username:

```sh
docker run --rm -it \
  -v "$PWD:/workspace" \
  -e LOCAL_USER_ID="$(id -u)" \
  -e LOCAL_GROUP_ID="$(id -g)" \
  -e LOCAL_USER_NAME="$(id -un)" \
  local-dev:latest
```

The image includes Go, Rust, Node 24, Python with pip/venv, Lua, Luau, Codex CLI, Claude Code CLI, Gemini CLI, Homebrew, Git 2.54.0, Git LFS, OpenSSH client, `ping`, jq, ripgrep (`rg`), `tree`, `less`, `pkg-config`, zip/unzip, pnpm, PostgreSQL, ffmpeg, ImageMagick, pandoc, WeasyPrint, bash, build tools, common dev headers, and the Docker CLI with the Compose plugin.

Codex is configured to run without its own sandbox inside this image because the container is the isolation boundary. Do not mount sensitive host paths into containers where Codex runs with broad autonomy. Use the safe Docker socket proxy below if Docker CLI access is needed.

Codex enhanced keyboard reporting is disabled by default with `CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT=1` to keep Ghostty/Kitty-style key sequences reliable through Docker TTYs. Set `CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT=0` before running `dev` if you want to try the enhanced mode.

### Persistent Tool State

For throwaway containers using the default `dev` user, keep the checkout mounted at `/workspace` and mount `dev-volume` as the container home. This keeps container-created home state such as `~/.codex` and `~/.ssh` available across dev containers without mounting `~/.ssh` from the host:

```sh
docker volume create dev-volume

docker run --rm -it \
  -v "$PWD:/workspace" \
  --mount type=volume,source=dev-volume,target=/home/dev \
  --mount type=bind,source="$HOME/.gitconfig",target=/home/dev/.gitconfig,readonly \
  local-dev:latest
```

Docker supports this mount layering: `dev-volume` backs `/home/dev`, and the more specific `.gitconfig` bind mount overlays only `/home/dev/.gitconfig`.

The entrypoint creates `~/.ssh` with `0700` permissions. Put container-specific SSH keys or config there from inside the container, and keep private keys at `0600` so OpenSSH accepts them. Any container that mounts `dev-volume` can access this SSH material.

Use the same shared home volume when mounting the safe Docker socket proxy:

```sh
docker run --rm -it \
  -v "$PWD:/workspace" \
  --mount type=volume,source=dev-volume,target=/home/dev \
  --mount type=bind,source="$HOME/.gitconfig",target=/home/dev/.gitconfig,readonly \
  -v docker-proxy:/var/run \
  local-dev:latest
```

### Git Worktrees

If you use Git worktrees from both the host and this container, use Git 2.48.0 or newer everywhere that will touch the repository. This image builds Git 2.54.0.

Enable relative worktree links in `~/.gitconfig` before creating worktrees:

```ini
[worktree]
    useRelativePaths = true
```

Equivalent command:

```sh
git config --global worktree.useRelativePaths true
```

The container sees the checkout at `/workspace`, while the host usually sees the same files at a different absolute path. Git worktrees store links between the main checkout and linked worktrees, so absolute links written in one environment may not exist in the other. Relative links keep the worktrees usable as long as the repository and its worktree directories move together.

Existing absolute-path worktrees should be recreated or repaired with Git 2.48.0 or newer:

```sh
git worktree repair --relative-paths
```

Relative worktree links enable Git's `extensions.relativeWorktrees` repository extension, so older Git versions will reject those repositories.

The Docker CLI and Compose plugin are client-only. To let them talk to the host Docker daemon, mount the safe Docker socket proxy volume when needed:

```sh
docker run --rm -it \
  -v "$PWD:/workspace" \
  --mount type=volume,source=dev-volume,target=/home/dev \
  --mount type=bind,source="$HOME/.gitconfig",target=/home/dev/.gitconfig,readonly \
  -v docker-proxy:/var/run \
  local-dev:latest
```

PostgreSQL is installed but not started automatically. Start the packaged cluster inside the container with:

```sh
sudo pg_ctlcluster 15 main start
```

## Safe Docker Socket

The tracked `.zshrc` sample fetches this from GitHub automatically before `dev_with_docker`. To start or refresh it manually, run:

```sh
curl -fsSL https://raw.githubusercontent.com/aduermael/env/main/safe-docker-socket.sh | sh
```

This starts or reuses a `dockerproxy` container that exposes a proxied Docker Unix socket as `docker.sock` inside the `docker-proxy` Docker volume. Containers can mount that volume at `/var/run` so Docker CLI commands use the proxy at `/var/run/docker.sock` by default, while the proxy binds the real Docker socket read-only and blocks bind mounts with `SP_ALLOWBINDMOUNTFROM=/.no-bind-mounts-allowed`.
