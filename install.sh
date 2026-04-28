#!/bin/bash
# claude-statusline installer for Linux/macOS
# Run: bash install.sh
set -e

src_script="$(cd "$(dirname "$0")" && pwd)/statusline.sh"
claude_dir="$HOME/.claude"
dst_script="$claude_dir/statusline.sh"
settings_file="$claude_dir/settings.local.json"

# --- Pre-flight ---
if [ ! -d "$claude_dir" ]; then
  echo "Error: $claude_dir does not exist. Is Claude Code installed?" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required (statusline parses JSON via jq)." >&2
  exit 1
fi

# --- Copy script ---
install -m 0755 "$src_script" "$dst_script"
echo "Copied statusline.sh -> $dst_script"

# --- Patch settings.local.json ---
# Set statusLine.{type,command,padding} via jq round-trip; create the
# file (with just statusLine) if it doesn't exist.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

if [ -f "$settings_file" ]; then
  jq --arg cmd "$dst_script" \
     '.statusLine = {type:"command", command:$cmd, padding:1}' \
     "$settings_file" >"$tmp"
  mv "$tmp" "$settings_file"
else
  jq -n --arg cmd "$dst_script" \
     '{statusLine:{type:"command", command:$cmd, padding:1}}' \
     >"$settings_file"
fi
echo "Patched $settings_file (statusLine -> $dst_script)"

# --- Add allow rule for the script under permissions.allow ---
# Idempotent: only adds if not already present.
allow_entry="Bash($dst_script)"
if jq -e --arg e "$allow_entry" '.permissions.allow | index($e)' "$settings_file" >/dev/null 2>&1; then
  echo "Allow rule already present: $allow_entry"
else
  jq --arg e "$allow_entry" \
     '.permissions = (.permissions // {}) | .permissions.allow = ((.permissions.allow // []) + [$e])' \
     "$settings_file" >"$tmp"
  mv "$tmp" "$settings_file"
  echo "Added allow rule: $allow_entry"
fi

echo
echo "Done. Restart any active Claude Code session for the statusline to take effect."
