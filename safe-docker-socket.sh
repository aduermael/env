#!/usr/bin/env sh
set -eu

container_name="${DOCKER_PROXY_CONTAINER:-dockerproxy}"
volume_name="${DOCKER_PROXY_VOLUME:-docker-proxy}"
host_socket="${DOCKER_HOST_SOCKET:-}"

if [ -z "${host_socket}" ]; then
  if [ -S "${HOME}/.docker/run/docker.sock" ]; then
    host_socket="${HOME}/.docker/run/docker.sock"
  else
    host_socket="/var/run/docker.sock"
  fi
fi

if [ ! -S "${host_socket}" ]; then
  echo "Docker socket not found at ${host_socket}; set DOCKER_HOST_SOCKET to override." >&2
  exit 1
fi

if [ "$(docker inspect -f '{{.State.Running}}' "${container_name}" 2>/dev/null || true)" = "true" ]; then
  exit 0
fi

docker rm -f "${container_name}" >/dev/null 2>&1 || true
docker volume create "${volume_name}" >/dev/null

docker run -d \
  --name "${container_name}" \
  --restart unless-stopped \
  --user 0:0 \
  --mount type=bind,src="${host_socket}",dst=/var/run/docker-host.sock,readonly \
  --mount type=volume,src="${volume_name}",dst=/docker-proxy \
  -e SP_LOGLEVEL=DEBUG \
  -e SP_SOCKETPATH=/var/run/docker-host.sock \
  -e SP_PROXYSOCKETENDPOINT=/docker-proxy/docker.sock \
  -e SP_PROXYSOCKETENDPOINTFILEMODE=0666 \
  -e SP_ALLOWBINDMOUNTFROM="/.no-bind-mounts-allowed" \
  -e SP_ALLOW_HEAD=".*" \
  -e SP_ALLOW_GET=".*" \
  -e SP_ALLOW_POST=".*" \
  -e SP_ALLOW_PUT=".*" \
  -e SP_ALLOW_DELETE=".*" \
  wollomatic/socket-proxy:1.12.1
