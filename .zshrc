# TERMINAL
PROMPT="$ "

# DOCKER
alias dps='docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"'
alias dpsp='docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Ports}}"'

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

dev() {
  _dev_run "$@"
}

dev_with_docker() {
  _dev_run -v /var/run/docker.sock:/var/run/docker.sock "$@"
}
