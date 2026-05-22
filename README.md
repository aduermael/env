# env
Environment setup files

## Local Dev Container

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

The image includes Go, Rust, Node 24, Python with pip/venv, Lua, Luau, Codex CLI, Claude Code CLI, Gemini CLI, Homebrew, Git 2.54.0, Git LFS, OpenSSH client, `ping`, jq, ripgrep (`rg`), `tree`, `less`, `pkg-config`, zip/unzip, bubblewrap, pnpm, PostgreSQL, ffmpeg, ImageMagick, pandoc, WeasyPrint, bash, build tools, common dev headers, and the Docker CLI with the Compose plugin.

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

Use the same shared home volume when mounting the Docker socket:

```sh
docker run --rm -it \
  -v "$PWD:/workspace" \
  --mount type=volume,source=dev-volume,target=/home/dev \
  --mount type=bind,source="$HOME/.gitconfig",target=/home/dev/.gitconfig,readonly \
  -v /var/run/docker.sock:/var/run/docker.sock \
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

The Docker CLI and Compose plugin are client-only. To let them talk to the host Docker daemon, mount a Docker socket when needed:

```sh
docker run --rm -it \
  -v "$PWD:/workspace" \
  --mount type=volume,source=dev-volume,target=/home/dev \
  --mount type=bind,source="$HOME/.gitconfig",target=/home/dev/.gitconfig,readonly \
  -v /var/run/docker.sock:/var/run/docker.sock \
  local-dev:latest
```

If you use the safe Docker socket proxy below, mount the proxy volume instead:

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

Run this from GitHub:

```sh
curl -fsSL https://raw.githubusercontent.com/aduermael/env/main/safe-docker-socket.sh | sh
```

This starts a `dockerproxy` container that exposes a proxied Docker Unix socket as `docker.sock` inside the `docker-proxy` Docker volume. Containers can mount that volume at `/var/run` so Docker CLI commands use the proxy at `/var/run/docker.sock` by default, while the proxy binds the real Docker socket read-only and blocks bind mounts with `SP_ALLOWBINDMOUNTFROM=/.no-bind-mounts-allowed`.
