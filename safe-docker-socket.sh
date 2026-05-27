#!/usr/bin/env sh
set -eu

command_name="${1:-up}"
container_name="${DOCKER_PROXY_CONTAINER:-${DEVENV_PROXY_CONTAINER:-devenv-dockerproxy}}"
proxy_image="${DOCKER_PROXY_IMAGE:-${DEVENV_PROXY_IMAGE:-wollomatic/socket-proxy:1.12.1}}"
host_socket="${DOCKER_HOST_SOCKET:-${DEVENV_HOST_DOCKER_SOCKET:-}}"
devenv_home="${DEVENV_HOME:-${HOME}/.devenv}"

case "${devenv_home}" in
  "~") devenv_home="${HOME}" ;;
  "~/"*) devenv_home="${HOME}/${devenv_home#~/}" ;;
esac

socket_dir="${DOCKER_PROXY_SOCKET_DIR:-${devenv_home}/run}"

case "${socket_dir}" in
  "~") socket_dir="${HOME}" ;;
  "~/"*) socket_dir="${HOME}/${socket_dir#~/}" ;;
esac

proxy_socket="${socket_dir%/}/docker.sock"
devenv_bin="$(command -v devenv 2>/dev/null || true)"
if [ -z "${devenv_bin}" ] && [ -x "${devenv_home}/bin/devenv" ]; then
  devenv_bin="${devenv_home}/bin/devenv"
fi
proxy_socket_filemode_args=""
if [ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]; then
  proxy_socket_filemode_args="-e SP_PROXYSOCKETENDPOINTFILEMODE=0666"
fi

proxy_is_healthy() {
  [ -S "${proxy_socket}" ] || return 1
  docker -H "unix://${proxy_socket}" version >/dev/null 2>&1
}

wait_for_proxy() {
  attempts="${DOCKER_PROXY_HEALTHCHECK_ATTEMPTS:-20}"
  interval="${DOCKER_PROXY_HEALTHCHECK_INTERVAL:-1}"
  attempt=1

  while [ "${attempt}" -le "${attempts}" ]; do
    if proxy_is_healthy; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep "${interval}"
  done

  return 1
}

case "${command_name}" in
  up|ensure) ;;
  down|teardown|rm)
    if [ -n "${devenv_bin}" ]; then
      DEVENV_HOME="${devenv_home}" \
        DEVENV_PROXY_CONTAINER="${container_name}" \
        DEVENV_PROXY_IMAGE="${proxy_image}" \
        "${devenv_bin}" down --root "${devenv_home}" --proxy-container "${container_name}"
      exit 0
    fi
    docker rm -f "${container_name}" >/dev/null 2>&1 || true
    exit 0
    ;;
  *)
    echo "usage: $0 [up|ensure|down|teardown|rm]" >&2
    exit 2
    ;;
esac

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

if [ "$(uname -s 2>/dev/null || echo unknown)" = "Darwin" ]; then
  if [ -n "${devenv_bin}" ]; then
    DEVENV_HOME="${devenv_home}" \
      DEVENV_PROXY_CONTAINER="${container_name}" \
      DEVENV_PROXY_IMAGE="${proxy_image}" \
      DEVENV_HOST_DOCKER_SOCKET="${host_socket}" \
      "${devenv_bin}" setup \
        --root "${devenv_home}" \
        --proxy-container "${container_name}" \
        --proxy-image "${proxy_image}" \
        --host-socket "${host_socket}" \
        --skip-build \
        --no-zshrc
    exit 0
  fi
  echo "Docker Desktop for macOS cannot expose this proxy as a bind-mounted Unix socket directly; run devenv setup instead." >&2
  exit 1
fi

mkdir -p "${devenv_home}" "${socket_dir}"
chmod 0700 "${devenv_home}" "${socket_dir}"

if [ "$(docker inspect -f '{{.State.Running}}' "${container_name}" 2>/dev/null || true)" = "true" ]; then
  if proxy_is_healthy; then
    exit 0
  fi
fi

docker rm -f "${container_name}" >/dev/null 2>&1 || true
rm -f "${proxy_socket}"

docker run -d \
  --name "${container_name}" \
  --restart unless-stopped \
  --user 0:0 \
  --label "com.aduermael.env.devenv.managed=true" \
  --label "com.aduermael.env.devenv.role=proxy" \
  --label "com.aduermael.env.devenv.root=${devenv_home}" \
  --mount type=bind,src="${host_socket}",dst=/var/run/docker-host.sock,readonly \
  --mount type=bind,src="${socket_dir}",dst=/docker-proxy \
  -e SP_LOGLEVEL=DEBUG \
  -e SP_SOCKETPATH=/var/run/docker-host.sock \
  -e SP_PROXYSOCKETENDPOINT=/docker-proxy/docker.sock \
  ${proxy_socket_filemode_args} \
  -e SP_ALLOWBINDMOUNTFROM="/.no-bind-mounts-allowed" \
  -e SP_ALLOW_HEAD=".*" \
  -e SP_ALLOW_GET=".*" \
  -e SP_ALLOW_POST=".*" \
  -e SP_ALLOW_PUT=".*" \
  -e SP_ALLOW_DELETE=".*" \
  "${proxy_image}" >/dev/null

if ! wait_for_proxy; then
  echo "Docker proxy did not become healthy at ${proxy_socket}." >&2
  docker logs --tail 50 "${container_name}" >&2 || true
  exit 1
fi
