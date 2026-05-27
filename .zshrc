# TERMINAL
PROMPT="$ "

# DOCKER
alias dps='docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"'
alias dpsp='docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Ports}}"'

_dev_safe_docker_socket_url="https://raw.githubusercontent.com/aduermael/env/main/safe-docker-socket.sh"

_dev_run() {
  local -a args=(
    --rm
    -it
    -v "$PWD:/workspace"
    --mount type=volume,source=dev-volume,target=/home/dev
    --mount "type=bind,source=$HOME/.gitconfig,target=/home/dev/.gitconfig,readonly"
  )

  docker run "${args[@]}" "$@" local-dev:latest
}

_dev_ensure_docker_proxy() {
  setopt local_options pipe_fail

  command curl -fsSL "$_dev_safe_docker_socket_url" | command sh
}

dev() {
  _dev_run "$@"
}

dev_with_docker() {
  _dev_ensure_docker_proxy || return
  _dev_run -v docker-proxy:/var/run "$@"
}
