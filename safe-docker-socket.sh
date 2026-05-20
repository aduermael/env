#!/usr/bin/env sh
set -eu

docker rm -f dockerproxy >/dev/null 2>&1 || true

docker run -d \
  --name dockerproxy \
  --restart unless-stopped \
  --user 0:0 \
  --mount type=bind,src="$HOME/.docker/run/docker.sock",dst=/var/run/docker-host.sock,readonly \
  --mount type=volume,src=docker-proxy,dst=/var/run \
  -e SP_LOGLEVEL=DEBUG \
  -e SP_SOCKETPATH=/var/run/docker-host.sock \
  -e SP_PROXYSOCKETENDPOINT=/var/run/docker.sock \
  -e SP_PROXYSOCKETENDPOINTFILEMODE=0666 \
  -e SP_ALLOWBINDMOUNTFROM="/.no-bind-mounts-allowed" \
  -e SP_ALLOW_HEAD=".*" \
  -e SP_ALLOW_GET=".*" \
  -e SP_ALLOW_POST=".*" \
  -e SP_ALLOW_PUT=".*" \
  -e SP_ALLOW_DELETE=".*" \
  wollomatic/socket-proxy:1.12.1
