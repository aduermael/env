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

The image includes Go, Node 24, Python, Lua, Luau, Codex CLI, Claude Code CLI, Gemini CLI, Homebrew, Git, Git LFS, jq, pnpm, PostgreSQL, bash, and the Docker CLI.

The Docker CLI is client-only. To let it talk to the host Docker daemon, mount a Docker socket when needed:

```sh
docker run --rm -it \
  -v "$PWD:/workspace" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  local-dev:latest
```

If you use the safe Docker socket proxy below, mount the proxy volume instead:

```sh
docker run --rm -it \
  -v "$PWD:/workspace" \
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
