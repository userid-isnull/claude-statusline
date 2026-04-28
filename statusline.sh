#!/bin/bash
# Claude Code status line — receives JSON on stdin, prints status lines
set -f

# --- Capture full payload for out-of-band rate-limit reads ---
# Claude Code only exposes rate_limits.* to the statusline command,
# not to hooks or stream-json. Tee-ing the JSON here gives any tool
# on the machine a way to snap the latest rate_limits values.
# Per-session file keyed by session_id avoids races; /tmp/statusline-
# latest.json always points at the most recent render.
__rl_payload=$(cat)
__rl_session=$(printf '%s' "$__rl_payload" | jq -r '.session_id // "unknown"' 2>/dev/null)
printf '%s\n' "$__rl_payload" >"/tmp/statusline-${__rl_session}.json" 2>/dev/null
printf '%s\n' "$__rl_payload" >"/tmp/statusline-latest.json" 2>/dev/null
exec < <(printf '%s' "$__rl_payload")

RST=$'\033[0m'
BRANCH=$'\ue0a0'

# --- Extract all fields from JSON stdin in one jq call ---
IFS=$'\x1f' read -r used_pct ctx_size in_tok out_tok proj_dir cur_dir \
  session_id wt_name \
  rl_5h_pct rl_5h_reset rl_7d_pct rl_7d_reset \
  <<< "$(jq -r '[
    (.context_window.used_percentage // 0 | floor),
    (.context_window.context_window_size // 200000),
    (.context_window.total_input_tokens // 0),
    (.context_window.total_output_tokens // 0),
    (.workspace.project_dir // ""),
    (.workspace.current_dir // .cwd // ""),
    (.session_id // ""),
    (.worktree.name // ""),
    (.rate_limits.five_hour.used_percentage // "" | if type == "number" then floor | tostring else . end),
    (.rate_limits.five_hour.resets_at // ""),
    (.rate_limits.seven_day.used_percentage // "" | if type == "number" then floor | tostring else . end),
    (.rate_limits.seven_day.resets_at // "")
  ] | join("\u001f")')"

used_pct=${used_pct:-0}
ctx_size=${ctx_size:-200000}
in_tok=${in_tok:-0}
out_tok=${out_tok:-0}

# --- Helpers ---

format_tokens() {
  local n=$1
  if [ "$n" -ge 1000000 ]; then
    printf '%s.%sM' "$((n / 1000000))" "$(( (n / 100000) % 10 ))"
  elif [ "$n" -ge 1000 ]; then
    printf '%sK' "$((n / 1000))"
  else
    printf '%s' "$n"
  fi
}

epoch_fmt() {
  date -d "@$1" +"$2" 2>/dev/null || date -r "$1" +"$2" 2>/dev/null || printf '???'
}

make_bar() {
  local pct=${1:-0} width=$2 divisor=$3
  local filled=$(( (pct + divisor / 2) / divisor ))
  [ "$filled" -gt "$width" ] && filled=$width
  [ "$filled" -lt 0 ] && filled=0
  local empty=$((width - filled))
  local bar=""
  [ "$filled" -gt 0 ] && bar=$(printf '%*s' "$filled" '' | sed 's/ /▓/g')
  [ "$empty" -gt 0 ] && bar="${bar}$(printf '%*s' "$empty" '' | sed 's/ /░/g')"
  printf '%s' "$bar"
}

# ============================================================
# LINE 1: Context + Rate Limits (no color)
# ============================================================

ctx_bar=$(make_bar "$used_pct" 10 10)
size_fmt=$(format_tokens "$ctx_size")

line1="${ctx_bar} ${used_pct}% / ${size_fmt} | ↑$(format_tokens "$in_tok") ↓$(format_tokens "$out_tok")"

if [ -n "$rl_5h_pct" ] && [ -n "$rl_5h_reset" ]; then
  rl5_bar=$(make_bar "$rl_5h_pct" 4 25)
  rl5_time=$(epoch_fmt "${rl_5h_reset}" %H:%M)
  line1="${line1} | 5h ${rl5_bar} ${rl_5h_pct}% ${rl5_time}"
fi

if [ -n "$rl_7d_pct" ] && [ -n "$rl_7d_reset" ]; then
  rl7_bar=$(make_bar "$rl_7d_pct" 4 25)
  if [ "$(epoch_fmt "${rl_7d_reset}" %F)" = "$(date +%F)" ]; then
    rl7_when=$(epoch_fmt "${rl_7d_reset}" %H:%M)
  else
    rl7_when=$(epoch_fmt "${rl_7d_reset}" %a)
  fi
  line1="${line1} | 7d ${rl7_bar} ${rl_7d_pct}% ${rl7_when}"
fi

# (line1 output deferred — all output buffered to end of script
#  to avoid partial-flush when stdout is line-buffered via pty)

# ============================================================
# LINE 2: Workspace (starship-style) + Session ID
# ============================================================

# --- SSH host detection + starship palette color ---
host_prefix=""
host_prefix_len=0

if [ -n "$SSH_CONNECTION" ]; then
  ssh_user=$(whoami)
  ssh_host=$(hostname -s)
  host_text=" ${ssh_user}@${ssh_host} "
  host_prefix_len=$(( ${#host_text} + 1 ))

  starship_cfg="${STARSHIP_CONFIG:-$HOME/.config/starship.toml}"
  if [ -f "$starship_cfg" ]; then
    palette=$(sed -n 's/^palette = "\(.*\)"/\1/p' "$starship_cfg" | head -1)
    if [ -n "$palette" ]; then
      color_hex=$(sed -n "/^\[palettes\.${palette}\]/,/^\[/{s/^color1 = \"\(.*\)\"/\1/p;}" "$starship_cfg" | head -1)
      if [ -n "$color_hex" ]; then
        hex="${color_hex#\#}"
        r=$((16#${hex:0:2})) g=$((16#${hex:2:2})) b=$((16#${hex:4:2}))
        host_prefix=$'\033'"[1;7;38;2;${r};${g};${b}m${host_text}${RST} "
      fi
    fi
  fi

  if [ -z "$host_prefix" ]; then
    host_prefix="${ssh_user}@${ssh_host} "
    host_prefix_len=$(( ${#ssh_user} + 1 + ${#ssh_host} + 1 ))
  fi
fi

# --- Git status (cached) ---
git_dir="${cur_dir:-$proj_dir}"
GIT_CACHE="/tmp/claude-sl-git"
now=$(date +%s)
git_branch=""
git_icons=""
is_git=false

if [ -n "$git_dir" ] && [ -d "$git_dir" ]; then
  need_refresh=true

  if [ -f "$GIT_CACHE" ]; then
    IFS=$'\x1f' read -r cached_dir cached_branch cached_icons cached_time < "$GIT_CACHE"
    if [ "$cached_dir" = "$git_dir" ] && [ -n "$cached_time" ] && [ $((now - cached_time)) -le 5 ]; then
      git_branch="$cached_branch"
      git_icons="$cached_icons"
      is_git=true
      need_refresh=false
    fi
  fi

  if $need_refresh && git -C "$git_dir" rev-parse --git-dir >/dev/null 2>&1; then
    is_git=true
    git_branch=$(git -C "$git_dir" branch --show-current 2>/dev/null)
    icons=""
    [ -n "$(git -C "$git_dir" diff --cached --numstat 2>/dev/null | head -1)" ] && icons="${icons}+"
    [ -n "$(git -C "$git_dir" diff --numstat 2>/dev/null | head -1)" ] && icons="${icons}!"
    [ -n "$(git -C "$git_dir" ls-files --others --exclude-standard 2>/dev/null | head -1)" ] && icons="${icons}?"
    git_icons="$icons"
    printf '%s\x1f%s\x1f%s\x1f%s' "$git_dir" "$git_branch" "$git_icons" "$now" > "$GIT_CACHE"
  fi
fi

# --- Build workspace string ---
ws_part=""

if $is_git; then
  proj_name="${proj_dir##*/}"
  ws_part="${proj_name}"

  branch_display="$git_branch"
  [ -n "$wt_name" ] && branch_display="$wt_name"

  if [ -n "$branch_display" ]; then
    ws_part="${ws_part} ${BRANCH} ${branch_display}"
  fi

  if [ -n "$git_icons" ]; then
    ws_part="${ws_part} [${git_icons}]"
  fi
else
  if [[ "$proj_dir" == "$HOME"* ]]; then
    ws_part="~${proj_dir:${#HOME}}"
  else
    ws_part="$proj_dir"
  fi
fi

# Working directory if different from project dir
if [ -n "$cur_dir" ] && [ "$cur_dir" != "$proj_dir" ]; then
  rel_cwd="${cur_dir#"$proj_dir"/}"
  [ "$rel_cwd" = "$cur_dir" ] && rel_cwd="${cur_dir##*/}"
  ws_part="${ws_part} > ./${rel_cwd}"
fi

sid_part="| ${session_id}"

# --- Width check (90 char limit) and output ---
total_len=$(( host_prefix_len + ${#ws_part} + 1 + ${#sid_part} ))

# --- Buffered output: emit all lines in one write ---
if [ "$total_len" -le 90 ]; then
  printf '%s\n%s%s %s\n' "$line1" "$host_prefix" "$ws_part" "$sid_part"
else
  printf '%s\n%s%s\n%s\n' "$line1" "$host_prefix" "$ws_part" "$sid_part"
fi
