# TERMINAL
PROMPT="$ "

# DOCKER
alias dps='docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"'
alias dpsp='docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Ports}}"'

dev() {
  docker run --rm -it \
    -v "$PWD:/workspace" \
    local-dev:latest
}
