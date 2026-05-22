# TERMINAL
PROMPT="$ "

# DOCKER
alias dps='docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"'
alias dpsp='docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Ports}}"'

dev() {
  docker run --rm -it \
    -v "$PWD:/workspace" \
    --mount type=bind,source="$HOME/.gitconfig",target=/home/dev/.gitconfig,readonly \
    -v dev-volume:/home/dev/.codex \
    local-dev:latest
}

dev_with_docker() {
  docker run --rm -it \
    -v "$PWD:/workspace" \
    --mount type=bind,source="$HOME/.gitconfig",target=/home/dev/.gitconfig,readonly \
    -v dev-volume:/home/dev/.codex \
    -v /var/run/docker.sock:/var/run/docker.sock \
    local-dev:latest
}
