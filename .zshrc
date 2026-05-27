# TERMINAL
PROMPT="$ "

# DOCKER
alias dps='docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"'
alias dpsp='docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Ports}}"'

_dev_safe_docker_socket_url="https://raw.githubusercontent.com/aduermael/env/main/safe-docker-socket.sh"

_dev_docker_run() {
  local -a args=(
    --rm
    -it
    -e "TERM=${TERM:-xterm-256color}"
    -e "CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT=${CODEX_TUI_DISABLE_KEYBOARD_ENHANCEMENT:-1}"
    -v "$PWD:/workspace"
    --mount type=volume,source=dev-volume,target=/home/dev
    --mount "type=bind,source=$HOME/.gitconfig,target=/home/dev/.gitconfig,readonly"
  )

  [[ -n "${COLORTERM:-}" ]] && args+=(-e "COLORTERM=$COLORTERM")
  [[ -n "${TERM_PROGRAM:-}" ]] && args+=(-e "TERM_PROGRAM=$TERM_PROGRAM")
  [[ -n "${TERM_PROGRAM_VERSION:-}" ]] && args+=(-e "TERM_PROGRAM_VERSION=$TERM_PROGRAM_VERSION")
  [[ -n "${KITTY_WINDOW_ID:-}" ]] && args+=(-e "KITTY_WINDOW_ID=$KITTY_WINDOW_ID")
  [[ -n "${WEZTERM_PANE:-}" ]] && args+=(-e "WEZTERM_PANE=$WEZTERM_PANE")
  [[ -n "${GHOSTTY_RESOURCES_DIR:-}" ]] && args+=(-e "GHOSTTY_RESOURCES_DIR=$GHOSTTY_RESOURCES_DIR")
  [[ -n "${VTE_VERSION:-}" ]] && args+=(-e "VTE_VERSION=$VTE_VERSION")

  docker run "${args[@]}" "$@"
}

_dev_run() {
  _dev_docker_run "$@" local-dev:latest
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

codex() {
  _dev_docker_run local-dev:latest codex "$@"
}

codex_with_docker() {
  _dev_ensure_docker_proxy || return
  _dev_docker_run -v docker-proxy:/var/run local-dev:latest codex "$@"
}
