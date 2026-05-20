# env
Environment setup files

## Safe Docker Socket

Run this from GitHub:

```sh
curl -fsSL https://raw.githubusercontent.com/aduermael/env/main/safe-docker-socket.sh | sh
```

This starts a `dockerproxy` container that exposes a proxied Docker Unix socket at `/var/run/docker.sock` inside the `docker-proxy` Docker volume. Containers can mount that volume at `/var/run` so Docker CLI commands use the proxy by default, while the proxy binds the real Docker socket read-only and blocks bind mounts with `SP_ALLOWBINDMOUNTFROM=/.no-bind-mounts-allowed`.
