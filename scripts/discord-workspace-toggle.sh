#!/bin/bash

set -euo pipefail

WORKSPACE_NAME="discord"
WORKSPACE="special:${WORKSPACE_NAME}"
DISCORD_CLASS='^chrome-discord\.com__.*-Default$'

workspace_visible() {
  hyprctl monitors -j | jq -e --arg ws "$WORKSPACE" 'any(.[]; .specialWorkspace.name == $ws)' >/dev/null
}

discord_window_exists() {
  hyprctl clients -j | jq -e --arg cls "$DISCORD_CLASS" 'any(.[]; .class | test($cls; "i"))' >/dev/null
}

discord_process_exists() {
  pgrep -fa -- '--app=https://discord.com/channels/@me' >/dev/null 2>&1
}

focus_discord_when_ready() {
  for _ in {1..50}; do
    if discord_window_exists; then
      hyprctl dispatch focuswindow "class:${DISCORD_CLASS}" >/dev/null
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

if discord_window_exists; then
  hyprctl dispatch focuswindow "class:${DISCORD_CLASS}" >/dev/null
  exit 0
fi

if ! discord_process_exists; then
  omarchy-launch-or-focus-webapp Discord "https://discord.com/channels/@me" >/dev/null 2>&1 &
fi

focus_discord_when_ready >/dev/null 2>&1 &
