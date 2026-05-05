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
BRANCH=$''
GRN=$'\033[32m'
YEL=$'\033[33m'
RED=$'\033[31m'
MAG=$'\033[95m'

# Now-epoch resolution: env override (deterministic tests) or system clock.
now=${STATUSLINE_NOW_EPOCH:-$(date +%s)}

# --- Extract all fields from JSON stdin in one jq call ---
IFS=$'\x1f' read -r model_name effort_level used_pct ctx_size \
  cu_in cu_out cu_cc cu_cr \
  proj_dir cur_dir session_id wt_name \
  rl_5h_pct rl_5h_reset rl_7d_pct rl_7d_reset \
  rl_s7d_pct rl_s7d_reset \
  <<< "$(jq -r '[
    (.model.display_name // ""),
    (.effort.level // ""),
    (.context_window.used_percentage // 0 | floor),
    (.context_window.context_window_size // 200000),
    (.context_window.current_usage.input_tokens // 0),
    (.context_window.current_usage.output_tokens // 0),
    (.context_window.current_usage.cache_creation_input_tokens // 0),
    (.context_window.current_usage.cache_read_input_tokens // 0),
    (.workspace.project_dir // ""),
    (.workspace.current_dir // .cwd // ""),
    (.session_id // ""),
    (.worktree.name // ""),
    (.rate_limits.five_hour.used_percentage // "" | if type == "number" then floor | tostring else . end),
    (.rate_limits.five_hour.resets_at // ""),
    (.rate_limits.seven_day.used_percentage // "" | if type == "number" then floor | tostring else . end),
    (.rate_limits.seven_day.resets_at // ""),
    ((.rate_limits.seven_day_sonnet.used_percentage // .rate_limits.seven_day.sonnet.used_percentage // "") | if type == "number" then floor | tostring else . end),
    (.rate_limits.seven_day_sonnet.resets_at // .rate_limits.seven_day.sonnet.resets_at // "")
  ] | join("")')"

used_pct=${used_pct:-0}
ctx_size=${ctx_size:-200000}

# Prefer the exact token count from context_window.current_usage (sum of
# input + output + cache_creation + cache_read). Falls back to the
# rounded-percentage estimate when the field is absent (early in session).
cur_tokens=$(( ${cu_in:-0} + ${cu_out:-0} + ${cu_cc:-0} + ${cu_cr:-0} ))
if [ "$cur_tokens" -le 0 ]; then
  cur_tokens=$(( used_pct * ctx_size / 100 ))
fi

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

# Generic bar (used for the 5h segment): width chars, integer divisor.
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

# Token-count danger-zone bands for the context bar (4 segments).
# < 100K: 1 segment, default; 100K-200K: 2, yellow;
# 200K-350K: 3, red; >= 350K: 4, vivid magenta.
# Output: "<filled>\x1f<ansi>"  (ansi may be empty)
get_ctx_band() {
  local t=$1
  if   [ "$t" -ge 350000 ]; then printf '%s\x1f%s' 4 "$MAG"
  elif [ "$t" -ge 200000 ]; then printf '%s\x1f%s' 3 "$RED"
  elif [ "$t" -ge 100000 ]; then printf '%s\x1f%s' 2 "$YEL"
  else                            printf '%s\x1f%s' 1 ""
  fi
}

render_ctx_bar() {
  local filled=$1 color=$2
  local w=4
  [ "$filled" -gt "$w" ] && filled=$w
  [ "$filled" -lt 0 ] && filled=0
  local empty=$(( w - filled ))
  local fillRun=""
  [ "$filled" -gt 0 ] && fillRun=$(printf '%*s' "$filled" '' | sed 's/ /▓/g')
  if [ -n "$color" ] && [ -n "$fillRun" ]; then
    fillRun="${color}${fillRun}${RST}"
  fi
  local emptyRun=""
  [ "$empty" -gt 0 ] && emptyRun=$(printf '%*s' "$empty" '' | sed 's/ /░/g')
  printf '%s%s' "$fillRun" "$emptyRun"
}

# 7d bar fill count (7 segments) — fills when pct crosses the halfway
# mark of each segment, i.e. at odd-fourteenths: 1/14, 3/14, ..., 13/14.
get_7d_filled() {
  local p=${1:-0}
  [ "$p" -lt 0 ] && p=0
  [ "$p" -gt 100 ] && p=100
  local f=$(( (14 * p + 100) / 200 ))
  [ "$f" -gt 7 ] && f=7
  [ "$f" -lt 0 ] && f=0
  printf '%s' "$f"
}

# 7d bar render with optional green "buffer" shading on the
# (pace_filled - actual_filled) segments immediately following the
# actual-filled run.
render_7d_bar() {
  local a=$1 p=$2
  local w=7
  [ "$a" -gt "$w" ] && a=$w
  [ "$p" -gt "$w" ] && p=$w
  [ "$a" -lt 0 ] && a=0
  [ "$p" -lt 0 ] && p=0
  local fillRun=""
  [ "$a" -gt 0 ] && fillRun=$(printf '%*s' "$a" '' | sed 's/ /▓/g')
  local segs="$fillRun"
  local tailN
  if [ "$p" -gt "$a" ]; then
    local bufN=$(( p - a ))
    local bufRun
    bufRun=$(printf '%*s' "$bufN" '' | sed 's/ /░/g')
    segs="${segs}${GRN}${bufRun}${RST}"
    tailN=$(( w - a - bufN ))
  else
    tailN=$(( w - a ))
  fi
  if [ "$tailN" -gt 0 ]; then
    segs="${segs}$(printf '%*s' "$tailN" '' | sed 's/ /░/g')"
  fi
  printf '%s' "$segs"
}

# Pace = how far through the 168h window we should be by now,
# expressed as integer percent in [0,100]. Float-divide via awk.
get_pace() {
  local resetsAt=$1 nowEpoch=$2
  if [ -z "$resetsAt" ]; then printf 0; return; fi
  awk -v r="$resetsAt" -v n="$nowEpoch" '
    BEGIN {
      h = (r - n) / 3600.0
      p = 100.0 * (168.0 - h) / 168.0
      if (p < 0) p = 0
      if (p > 100) p = 100
      printf "%d", int(p)
    }'
}

# Countdown: at >= 24h, "(NdMh)"; at < 24h, "(Nh)"; at <= 0, "(0h)".
get_countdown() {
  local resetsAt=$1 nowEpoch=$2
  [ -z "$resetsAt" ] && return
  local secs=$(( resetsAt - nowEpoch ))
  if [ "$secs" -le 0 ]; then printf '(0h)'; return; fi
  local hours=$(( secs / 3600 ))
  if [ "$hours" -ge 24 ]; then
    local days=$(( hours / 24 ))
    local rem=$(( hours - days * 24 ))
    printf '(%dd%dh)' "$days" "$rem"
  else
    printf '(%dh)' "$hours"
  fi
}

# ============================================================
# LINE 1: Model + Context + Rate Limits
# ============================================================

IFS=$'\x1f' read -r ctx_filled ctx_color <<< "$(get_ctx_band "$cur_tokens")"
ctx_bar=$(render_ctx_bar "$ctx_filled" "$ctx_color")

line1="${ctx_bar} ${used_pct}% ($(format_tokens "$cur_tokens")) / $(format_tokens "$ctx_size")"

if [ -n "$rl_5h_pct" ] && [ -n "$rl_5h_reset" ]; then
  rl5_bar=$(make_bar "$rl_5h_pct" 4 25)
  rl5_time=$(epoch_fmt "${rl_5h_reset}" %H:%M)
  line1="${line1} | 5h ${rl5_bar} ${rl_5h_pct}% ${rl5_time}"
fi

if [ -n "$rl_7d_pct" ] && [ -n "$rl_7d_reset" ]; then
  rl7_pace=$(get_pace "$rl_7d_reset" "$now")
  rl7_a=$(get_7d_filled "$rl_7d_pct")
  rl7_p=$(get_7d_filled "$rl7_pace")
  rl7_bar=$(render_7d_bar "$rl7_a" "$rl7_p")
  hoursToReset=$(( (rl_7d_reset - now) / 3600 ))
  if [ "$hoursToReset" -lt 24 ]; then
    rl7_when=$(epoch_fmt "${rl_7d_reset}" %H:%M)
  else
    rl7_when=$(epoch_fmt "${rl_7d_reset}" %a)
  fi
  rl7_cd=$(get_countdown "$rl_7d_reset" "$now")
  line1="${line1} | 7d ${rl7_bar} ${rl_7d_pct}%/${rl7_pace}% ${rl7_when} ${rl7_cd}"
fi

if [ -n "$rl_s7d_pct" ] && [ -n "$rl_s7d_reset" ]; then
  rls7d_pace=$(get_pace "$rl_s7d_reset" "$now")
  rls7d_a=$(get_7d_filled "$rl_s7d_pct")
  rls7d_p=$(get_7d_filled "$rls7d_pace")
  rls7d_bar=$(render_7d_bar "$rls7d_a" "$rls7d_p")
  line1="${line1} | s7d ${rls7d_bar} ${rl_s7d_pct}%/${rls7d_pace}%"
fi

# Prepend short model name + optional effort to line 1.
# display_name like "Opus 4.7 (1M context)" → first word ("Opus"); append ":<effort>" when present.
if [ -n "$model_name" ]; then
  model_short="${model_name%% *}"
  [ -n "$effort_level" ] && model_short="${model_short}:${effort_level}"
  line1="${model_short} ${line1}"
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
gitNow=$(date +%s)
git_branch=""
git_icons=""
is_git=false

if [ -n "$git_dir" ] && [ -d "$git_dir" ]; then
  need_refresh=true

  if [ -f "$GIT_CACHE" ]; then
    IFS=$'\x1f' read -r cached_dir cached_branch cached_icons cached_time < "$GIT_CACHE"
    if [ "$cached_dir" = "$git_dir" ] && [ -n "$cached_time" ] && [ $((gitNow - cached_time)) -le 5 ]; then
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
    printf '%s\x1f%s\x1f%s\x1f%s' "$git_dir" "$git_branch" "$git_icons" "$gitNow" > "$GIT_CACHE"
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
