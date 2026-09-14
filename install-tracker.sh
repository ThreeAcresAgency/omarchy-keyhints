#!/bin/bash
# Install (or remove) the keybinding usage tracker that feeds the keyhints
# bar widget. The Omarchy plugin installer only copies files, so this step is
# separate: it puts hypr/keyhints.lua into ~/.config/hypr/ and loads it from
# hyprland.lua ahead of the Omarchy defaults.
#
#   ./install-tracker.sh              install and reload Hyprland
#   ./install-tracker.sh --uninstall  remove the tracker (keeps the usage log)
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
hypr_dir="$HOME/.config/hypr"
tracker="$hypr_dir/keyhints.lua"
config="$hypr_dir/hyprland.lua"
state_dir="$HOME/.local/state/omarchy/keyhints"
require_line='require("hypr.keyhints")'
comment_line='-- Keybinding usage tracker for the keyhints bar widget (see hypr/keyhints.lua).'

if [[ "${1:-}" == "--uninstall" ]]; then
  [[ -f "$config" ]] && sed -i "/^${comment_line//\//\\/}$/d; /^${require_line//\//\\/}$/d" "$config"
  rm -f "$tracker"
  hyprctl reload >/dev/null
  echo "Removed $tracker and its require line from hyprland.lua."
  echo "Usage log kept at $state_dir/usage.log; delete it if you want a clean slate."
  exit 0
fi

if [[ ! -f "$config" ]]; then
  echo "No $config found. This tracker needs Omarchy's Lua Hyprland config." >&2
  exit 1
fi

mkdir -p "$state_dir"
install -m 0644 "$here/hypr/keyhints.lua" "$tracker"

if ! grep -qF "$require_line" "$config"; then
  if ! grep -q '^require("default.hypr.omarchy")' "$config"; then
    echo "Could not find require(\"default.hypr.omarchy\") in $config." >&2
    echo "Add $require_line just before it by hand." >&2
    exit 1
  fi
  cp "$config" "$config.bak.keyhints.$(date +%s)"
  # The tracker must load before the defaults so every binding passes through it.
  sed -i "s|^require(\"default.hypr.omarchy\")|$comment_line\n$require_line\n\nrequire(\"default.hypr.omarchy\")|" "$config"
fi

hyprctl reload >/dev/null
if [[ -n "$(hyprctl configerrors)" ]]; then
  echo "Hyprland reported config errors after installing the tracker:" >&2
  hyprctl configerrors >&2
  exit 1
fi

echo "Tracker installed. Keybinding presses now log to $state_dir/usage.log."
