#!/bin/bash

set -euo pipefail

WORKSPACE_NAME="music"
WORKSPACE="special:${WORKSPACE_NAME}"
SPOTIFY_CLASS='^(spotify)$'

workspace_visible() {
  hyprctl monitors -j | jq -e --arg ws "$WORKSPACE" 'any(.[]; .specialWorkspace.name == $ws)' >/dev/null
}

spotify_window_exists() {
  hyprctl clients -j | jq -e --arg cls "$SPOTIFY_CLASS" 'any(.[]; .class | test($cls; "i"))' >/dev/null
}

spotify_process_exists() {
  pgrep -x spotify >/dev/null 2>&1
}

focus_spotify_when_ready() {
  for _ in {1..50}; do
    if spotify_window_exists; then
      hyprctl dispatch focuswindow "class:${SPOTIFY_CLASS}" >/dev/null
      return 0
    fi
    sleep 0.1
  done
  return 1
}

if workspace_visible; then
  hyprctl dispatch togglespecialworkspace "$WORKSPACE_NAME" >/dev/null
  exit 0
fi

hyprctl dispatch togglespecialworkspace "$WORKSPACE_NAME" >/dev/null

if spotify_window_exists; then
  hyprctl dispatch focuswindow "class:${SPOTIFY_CLASS}" >/dev/null
  exit 0
fi

if ! spotify_process_exists; then
  omarchy-launch-or-focus spotify >/dev/null 2>&1 &
fi

focus_spotify_when_ready >/dev/null 2>&1 &
