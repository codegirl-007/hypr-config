#!/bin/bash

set -euo pipefail

WORKSPACE_NAME="ai"
WORKSPACE="special:${WORKSPACE_NAME}"
WINDOW_CLASS='^AI-Drawer$'
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/hypr"
STATE_FILE="${STATE_DIR}/ai-workspace-path"

workspace_visible() {
  hyprctl monitors -j | jq -e --arg ws "$WORKSPACE" 'any(.[]; .specialWorkspace.name == $ws)' >/dev/null
}

show_workspace() {
  if ! workspace_visible; then
    hyprctl dispatch togglespecialworkspace "$WORKSPACE_NAME" >/dev/null
  fi
}

get_ai_window_address() {
  hyprctl clients -j | jq -r --arg cls "$WINDOW_CLASS" 'first(.[] | select(.class | test($cls)) | .address) // empty'
}

ai_window_exists() {
  [[ -n "$(get_ai_window_address)" ]]
}

normalize_dir() {
  local path

  path=$(readlink -f -- "$1" 2>/dev/null || true)
  if [[ -n "$path" && -d "$path" ]]; then
    printf '%s\n' "$path"
    return 0
  fi

  return 1
}

get_terminal_cwd_from_pid() {
  local terminal_pid="$1"
  local shell_pid
  local cwd
  local shell

  shell_pid=$(pgrep -P "$terminal_pid" | tail -n1 || true)

  if [[ -z "$shell_pid" ]]; then
    return 1
  fi

  cwd=$(readlink -f "/proc/$shell_pid/cwd" 2>/dev/null || true)
  shell=$(readlink -f "/proc/$shell_pid/exe" 2>/dev/null || true)

  if [[ -n "$cwd" && -d "$cwd" && -n "$shell" ]] && grep -qs "$shell" /etc/shells; then
    printf '%s\n' "$cwd"
    return 0
  fi

  return 1
}

find_tmux_client_pid() {
  local root_pid="$1"
  local queue=()
  local pid
  local child_pid
  local child_comm
  local child_args

  queue+=("$root_pid")

  while ((${#queue[@]})); do
    pid="${queue[0]}"
    queue=("${queue[@]:1}")

    while read -r child_pid child_comm child_args; do
      [[ -z "$child_pid" ]] && continue

      if [[ "$child_comm" == tmux:* || "$child_comm" == tmux || "$child_args" == tmux* || "$child_args" == */tmux* ]]; then
        printf '%s\n' "$child_pid"
        return 0
      fi

      queue+=("$child_pid")
    done < <(ps -o pid=,comm=,args= --ppid "$pid")
  done

  return 1
}

get_tmux_client_tty() {
  local terminal_pid="$1"
  local tmux_client_pid

  tmux_client_pid=$(find_tmux_client_pid "$terminal_pid" || true)

  if [[ -z "$tmux_client_pid" ]]; then
    return 1
  fi

  tmux list-clients -F '#{client_pid} #{client_tty}' | awk -v pid="$tmux_client_pid" '$1 == pid { print $2; exit }'
}

get_tmux_pane_path() {
  local terminal_pid="$1"
  local client_tty
  local pane_path

  client_tty=$(get_tmux_client_tty "$terminal_pid" || true)

  if [[ -z "$client_tty" ]]; then
    return 1
  fi

  pane_path=$(tmux display-message -p -t "$client_tty" '#{pane_current_path}' 2>/dev/null || true)

  if [[ -n "$pane_path" ]]; then
    normalize_dir "$pane_path"
    return 0
  fi

  return 1
}

get_process_cwd() {
  local pid="$1"
  local cwd

  cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)

  if [[ -n "$cwd" && -d "$cwd" ]]; then
    printf '%s\n' "$cwd"
    return 0
  fi

  return 1
}

get_requested_path() {
  local active_window
  local terminal_pid
  local requested_path
  local active_class

  active_window=$(hyprctl activewindow -j)
  terminal_pid=$(jq -r '.pid // empty' <<<"$active_window")
  active_class=$(jq -r '.class // empty' <<<"$active_window")

  if [[ "$active_class" == "AI-Drawer" ]]; then
    requested_path=$(read_saved_path || true)
    if [[ -n "$requested_path" ]]; then
      printf '%s\n' "$requested_path"
      return 0
    fi

    if [[ -n "$terminal_pid" ]]; then
      requested_path=$(get_process_cwd "$terminal_pid" || true)
      if [[ -n "$requested_path" ]]; then
        printf '%s\n' "$requested_path"
        return 0
      fi
    fi
  fi

  if [[ -n "$terminal_pid" ]]; then
    requested_path=$(get_tmux_pane_path "$terminal_pid" || true)
    if [[ -n "$requested_path" ]]; then
      printf '%s\n' "$requested_path"
      return 0
    fi

    requested_path=$(get_terminal_cwd_from_pid "$terminal_pid" || true)
    if [[ -n "$requested_path" ]]; then
      printf '%s\n' "$requested_path"
      return 0
    fi
  fi

  normalize_dir "$HOME"
}

read_saved_path() {
  if [[ -f "$STATE_FILE" ]]; then
    normalize_dir "$(<"$STATE_FILE")" || true
  fi
}

write_saved_path() {
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$1" > "$STATE_FILE"
}

close_ai_window() {
  local address

  address=$(get_ai_window_address)
  if [[ -z "$address" ]]; then
    return 0
  fi

  hyprctl dispatch closewindow "address:${address}" >/dev/null

  for _ in {1..50}; do
    if ! ai_window_exists; then
      return 0
    fi
    sleep 0.1
  done

  return 1
}

focus_ai_when_ready() {
  for _ in {1..50}; do
    if ai_window_exists; then
      hyprctl dispatch focuswindow "class:${WINDOW_CLASS}" >/dev/null
      return 0
    fi
    sleep 0.1
  done

  return 1
}

launch_ai_window() {
  local path="$1"

  show_workspace
  uwsm-app -- alacritty --class AI-Drawer --working-directory "$path" -e opencode "$path" --continue >/dev/null 2>&1 &
  write_saved_path "$path"
  focus_ai_when_ready >/dev/null 2>&1 &
}

main() {
  local requested_path
  local saved_path
  local print_path=false

  if [[ "${1:-}" == "--print-path" ]]; then
    print_path=true
    shift
  fi

  requested_path="${1:-}"
  if [[ -z "$requested_path" ]]; then
    requested_path=$(get_requested_path)
  else
    requested_path=$(normalize_dir "$requested_path")
  fi

  if [[ "$print_path" == true ]]; then
    printf '%s\n' "$requested_path"
    exit 0
  fi

  saved_path=$(read_saved_path || true)

  if ai_window_exists; then
    if [[ -n "$saved_path" && "$saved_path" == "$requested_path" ]]; then
      hyprctl dispatch togglespecialworkspace "$WORKSPACE_NAME" >/dev/null
      exit 0
    fi

    close_ai_window
  fi

  launch_ai_window "$requested_path"
}

main "$@"
