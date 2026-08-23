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

# --- omp usage source (optional) ---
# `omp usage --json` exposes provider rate limits Claude Code's statusline
# payload lacks (Fable-tier weekly, OpenAI Codex windows, 5h/7d when Claude
# Code withholds them). Cached for STATUSLINE_OMP_TTL seconds (default 60 —
# /usage is IP-rate-limited upstream and omp startup costs ~1s). A failed
# refresh keeps the previous cache; no omp or no cache means the Claude Code
# fields above are used unchanged.
OMP_TTL=${STATUSLINE_OMP_TTL:-60}
OMP_CACHE=${STATUSLINE_OMP_CACHE:-"${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline/omp-usage.json"}
if [ "${STATUSLINE_OMP_DISABLE:-0}" = 0 ] && command -v omp >/dev/null 2>&1; then
  cache_age=$(( OMP_TTL + 1 ))
  if [ -r "$OMP_CACHE" ]; then
    cache_mtime=$(stat -c %Y "$OMP_CACHE" 2>/dev/null || stat -f %m "$OMP_CACHE" 2>/dev/null || echo 0)
    cache_age=$(( now - cache_mtime ))
  fi
  if [ "$cache_age" -ge "$OMP_TTL" ]; then
    omp_fresh=$(timeout "${STATUSLINE_OMP_TIMEOUT:-10}" omp usage --json 2>/dev/null) || omp_fresh=""
    case "$omp_fresh" in
      *'"reports"'*)
        mkdir -p "$(dirname "$OMP_CACHE")" 2>/dev/null
        printf '%s' "$omp_fresh" >"${OMP_CACHE}.tmp" 2>/dev/null \
          && mv -f "${OMP_CACHE}.tmp" "$OMP_CACHE" 2>/dev/null
        ;;
    esac
  fi
  if [ -r "$OMP_CACHE" ]; then
    IFS=$'\x1f' read -r \
      o5h_pct o5h_reset o7d_pct o7d_reset ofb_pct ofb_rst osn_pct osn_rst \
      ocodex_recs \
      <<< "$(jq -r '
        def L($id): first(.reports[]? | select(.provider == "anthropic")
                          | .limits[]? | select(.id == $id)) // null;
        def P($l): if $l == null then "" else ($l.amount.used // "" | tostring) end;
        # omp resetsAt is epoch milliseconds; the status line works in seconds.
        def R($l): if ($l.window.resetsAt // null) == null then ""
                   else (($l.window.resetsAt / 1000) | floor | tostring) end;
        [
          (L("anthropic:5h") | P(.)), (L("anthropic:5h") | R(.)),
          (L("anthropic:7d") | P(.)), (L("anthropic:7d") | R(.)),
          (L("anthropic:7d:fable") | P(.)), (L("anthropic:7d:fable") | R(.)),
          (L("anthropic:7d:sonnet") | P(.)), (L("anthropic:7d:sonnet") | R(.)),
          ([ .reports[]? | select(.provider == "openai-codex") | .limits[]?
             | [ (.amount.used // "" | tostring),
                 ((.window.resetsAt // null)
                  | if . == null then "" else ((. / 1000) | floor | tostring) end),
                 ((.window.durationMs // 0) | floor | tostring) ]
               | join("\u001f") ] | join("\u001e"))
        ] | join("\u001f")' "$OMP_CACHE" 2>/dev/null)"

    # Fill gaps only: a value Claude Code already supplied stays authoritative,
    # so mid-session data never regresses to an older omp snapshot.
    [ -z "$rl_5h_pct" ]   && [ -n "$o5h_pct" ]   && { rl_5h_pct=$o5h_pct;     rl_5h_reset=$o5h_reset; }
    [ -z "$rl_7d_pct" ]   && [ -n "$o7d_pct" ]   && { rl_7d_pct=$o7d_pct;     rl_7d_reset=$o7d_reset; }
    [ -z "$rl_s7d_pct" ]  && [ -n "$osn_pct" ]   && { rl_s7d_pct=$osn_pct;    rl_s7d_reset=$osn_rst; }
  fi
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

# Render the context bar from a pre-computed fill count + optional color.
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

# Pace = how far through the usage window we should be by now, expressed as
# integer percent in [0,100]. Float-divide via awk. windowSecs defaults to the
# 168h weekly window; omp-backed segments pass their own durationMs.
get_pace() {
  local resetsAt=$1 nowEpoch=$2 windowSecs=${3:-604800}
  if [ -z "$resetsAt" ]; then printf 0; return; fi
  awk -v r="$resetsAt" -v n="$nowEpoch" -v w="$windowSecs" '
    BEGIN {
      p = 100.0 * (n - (r - w)) / w
      if (p < 0) p = 0
      if (p > 100) p = 100
      printf "%d", int(p)
    }'
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

if [ -n "$rl_5h_pct" ]; then
  rl5_bar=$(make_bar "$rl_5h_pct" 4 25)
  rl5_time=""
  [ -n "$rl_5h_reset" ] && rl5_time=$(epoch_fmt "${rl_5h_reset}" %H:%M)
  line1="${line1} | 5h ${rl5_bar} ${rl_5h_pct}%${rl5_time:+ ${rl5_time}}"
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

# omp-only segments (no Claude Code payload equivalent). Same bar + pace
# render as s7d; Fable is a weekly window like 7d, Codex windows are labeled
# by their own durationMs (c5h / c7d).
if [ -n "$ofb_pct" ] && [ -n "$ofb_rst" ]; then
  ofb_pace=$(get_pace "$ofb_rst" "$now")
  ofb_a=$(get_7d_filled "$ofb_pct")
  ofb_p=$(get_7d_filled "$ofb_pace")
  ofb_bar=$(render_7d_bar "$ofb_a" "$ofb_p")
  line1="${line1} | f7d ${ofb_bar} ${ofb_pct}%/${ofb_pace}%"
fi

if [ -n "${ocodex_recs:-}" ]; then
  IFS=$'\x1e' read -ra codex_arr <<< "$ocodex_recs"
  for codex_rec in "${codex_arr[@]}"; do
    IFS=$'\x1f' read -r cx_pct cx_reset cx_durms <<< "$codex_rec"
    [ -n "$cx_pct" ] || continue
    case "$cx_durms" in
      18000000)  cx_label="c5h" ;;
      604800000) cx_label="c7d" ;;
      *)         cx_label="cx" ;;
    esac
    cx_winsecs=$(( cx_durms / 1000 ))
    cx_pace=$(get_pace "$cx_reset" "$now" "$cx_winsecs")
    cx_a=$(get_7d_filled "$cx_pct")
    cx_p=$(get_7d_filled "$cx_pace")
    cx_bar=$(render_7d_bar "$cx_a" "$cx_p")
    line1="${line1} | ${cx_label} ${cx_bar} ${cx_pct}%/${cx_pace}%"
  done
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
# Direct env vars cover the ordinary case. The /proc parent walk is the
# fallback for terminal multiplexers (zellij, tmux, screen) whose
# long-running server inherits SSH_* once at launch and then spawns
# panes whose own env never carried those vars. Walking up to the
# server process recovers the original SSH context.
is_ssh_session() {
  if [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_CLIENT:-}" ] || [ -n "${SSH_TTY:-}" ]; then
    return 0
  fi
  [ "${STATUSLINE_SSH_PROBE_PROC:-1}" = 1 ] || return 1

  local pid=$$ depth=0 ppid env_blob
  local has_proc=0
  [ -r /proc/self/environ ] && has_proc=1

  while [ -n "$pid" ] && [ "$pid" != "1" ] && [ "$pid" != "0" ] && [ "$depth" -lt 20 ]; do
    if [ "$has_proc" = 1 ] && [ -r "/proc/$pid/environ" ]; then
      env_blob=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null)
    else
      # macOS / BSD: `ps eww` prints env tokens after the command. Tokens are
      # space-separated KEY=VALUE pairs; splitting on whitespace + grep is
      # good enough to detect presence of SSH_*. Restricted to same-UID procs.
      env_blob=$(ps eww -p "$pid" 2>/dev/null | tail -n +2 | tr ' \t' '\n\n')
    fi
    if printf '%s\n' "$env_blob" | grep -qE '^SSH_(CONNECTION|CLIENT|TTY)='; then
      return 0
    fi
    if [ "$has_proc" = 1 ] && [ -r "/proc/$pid/status" ]; then
      ppid=$(awk '/^PPid:/ {print $2; exit}' "/proc/$pid/status" 2>/dev/null)
    else
      ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    fi
    { [ -z "$ppid" ] || [ "$ppid" = "$pid" ]; } && return 1
    pid=$ppid
    depth=$((depth + 1))
  done
  return 1
}

host_prefix=""
host_prefix_len=0

if is_ssh_session; then
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
