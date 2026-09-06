#!/bin/bash
# Claude Code status line — receives JSON on stdin, prints status lines
set -f

# --- Capture full payload for out-of-band rate-limit reads ---
# Claude Code only exposes rate_limits.* to the statusline command,
# not to hooks or stream-json. Tee-ing the JSON here gives any tool
# on the machine a way to snap the latest rate_limits values.
# Per-session file keyed by session_id avoids races; /tmp/statusline-
# latest.json always points at the most recent Claude render.
#
# A non-Claude driver such as the omp footer extension also renders through
# this script. shift-change's clock-out.sh recovers a Claude session id from
# /tmp/statusline-latest.json, so an omp render must not clobber either tee.
__rl_payload=$(cat)
if [ "${STATUSLINE_PAYLOAD_TEE:-1}" != "0" ]; then
  __rl_session=$(printf '%s' "$__rl_payload" | jq -r '.session_id // "unknown"' 2>/dev/null)
  printf '%s\n' "$__rl_payload" >"/tmp/statusline-${__rl_session}.json" 2>/dev/null
  printf '%s\n' "$__rl_payload" >"/tmp/statusline-latest.json" 2>/dev/null
fi
exec < <(printf '%s' "$__rl_payload")

RST=$'\033[0m'
BRANCH=$''
WTREE=''
GRN=$'\033[32m'
YEL=$'\033[33m'
RED=$'\033[31m'
MAG=$'\033[95m'

# Provider and window glyphs for the two quota rows (nerd font). Written as
# literal UTF-8, not $'\uXXXX': macOS ships bash 3.2, which predates \u and
# would print the escape text verbatim. tests/lib.sh mirrors these.
G_CLAUDE=''
G_CODEX='󰰗'
G_5H='󰇎'
G_SPARK5H='󱅎'
G_7D=''
G_FABLE='󰯻'
G_SPARK=''
SEP='│'

# Now-epoch resolution: env override (deterministic tests) or system clock.
now=${STATUSLINE_NOW_EPOCH:-$(date +%s)}

# --- Extract all fields from JSON stdin in one jq call ---
IFS=$'\x1f' read -r model_name effort_level used_pct ctx_size \
  cu_in cu_out cu_cc cu_cr \
  proj_dir cur_dir session_id \
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
if [ "${STATUSLINE_OMP_DISABLE:-0}" = 0 ]; then
  cache_age=$(( OMP_TTL + 1 ))
  if [ -r "$OMP_CACHE" ]; then
    cache_mtime=$(stat -c %Y "$OMP_CACHE" 2>/dev/null || stat -f %m "$OMP_CACHE" 2>/dev/null || echo 0)
    cache_age=$(( now - cache_mtime ))
  fi
  if [ "$cache_age" -ge "$OMP_TTL" ] && command -v omp >/dev/null 2>&1; then
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
        def L($id):
          first(.reports[]? | select(.provider == "anthropic")
                | .limits[]?
                | select(.id == $id
                         and .amount.unit == "percent"
                         and (.amount.used | type == "number"))) // null;
        def P($l):
          if $l == null then "" else ($l.amount.used | floor | tostring) end;
        # omp resetsAt is epoch milliseconds; the status line works in seconds.
        def R($l):
          if ($l == null) or (($l.window.resetsAt? | type) != "number") then ""
          else (($l.window.resetsAt / 1000) | floor | tostring)
          end;
        def W:
          if (.scope.windowId? // "") != "" then .scope.windowId
          elif (.window.id? // "") != "" then .window.id
          elif .window.durationMs? == 18000000 then "5h"
          elif .window.durationMs? == 604800000 then "7d"
          else ""
          end;
        def D($kind):
          if ((.window.durationMs? | type) == "number") and (.window.durationMs > 0)
          then (.window.durationMs / 1000 | floor | tostring)
          elif $kind == "5h" then "18000"
          elif $kind == "7d" then "604800"
          else ""
          end;
        def C:
          . as $limit
          | ($limit | W) as $kind
          | if (($kind == "5h" or $kind == "7d")
                and $limit.amount.unit == "percent"
                and ($limit.amount.used | type == "number"))
            then [
              ((if $limit.scope.tier? == "spark"
                   or (($limit.id // "") | contains(":spark:"))
                then "cs" else "c" end) + $kind),
              ($limit.amount.used | floor | tostring),
              (R($limit)),
              ($limit | D($kind))
            ] | join("\u001f")
            else empty
            end;
        [
          (L("anthropic:5h") | P(.)), (L("anthropic:5h") | R(.)),
          (L("anthropic:7d") | P(.)), (L("anthropic:7d") | R(.)),
          (L("anthropic:7d:fable") | P(.)), (L("anthropic:7d:fable") | R(.)),
          (L("anthropic:7d:sonnet") | P(.)), (L("anthropic:7d:sonnet") | R(.)),
          ([ .reports[]? | select(.provider == "openai-codex") | .limits[]? | C ]
            | join("\u001e"))
        ] | join("\u001f")' "$OMP_CACHE" 2>/dev/null)"

    # Fill only payload fields that are absent. Claude Code values remain
    # authoritative, while a partial payload can still use a cached reset or
    # percentage for its missing half.
    [ -z "$rl_5h_pct" ]   && [ -n "$o5h_pct" ]   && rl_5h_pct=$o5h_pct
    [ -z "$rl_5h_reset" ] && [ -n "$o5h_reset" ] && rl_5h_reset=$o5h_reset
    [ -z "$rl_7d_pct" ]   && [ -n "$o7d_pct" ]   && rl_7d_pct=$o7d_pct
    [ -z "$rl_7d_reset" ] && [ -n "$o7d_reset" ] && rl_7d_reset=$o7d_reset
    [ -z "$rl_s7d_pct" ]  && [ -n "$osn_pct" ]   && rl_s7d_pct=$osn_pct
    [ -z "$rl_s7d_reset" ] && [ -n "$osn_rst" ]  && rl_s7d_reset=$osn_rst
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

# Render a quota as a colored actual percentage followed by an uncolored pace
# percentage: at or under pace is green, over pace is red. A window with no
# reset time has no knowable pace — `omp usage --json` omits `resetsAt` on an
# untouched window — so it degrades to a bare uncolored percentage rather than
# claiming a pace of zero or disappearing.
format_paced_usage() {
  local actual=$1 resetsAt=$2 nowEpoch=$3 windowSecs=${4:-604800}
  if [ -z "$resetsAt" ]; then
    printf '%s%%' "$actual"
    return
  fi
  local pace color=$RED
  pace=$(get_pace "$resetsAt" "$nowEpoch" "$windowSecs")
  [ "$actual" -le "$pace" ] && color=$GRN
  printf '%s%s%%%s/%s%%' "$color" "$actual" "$RST" "$pace"
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

# Reset of a multi-day window, at the precision that is actionable at that
# range: beyond 24h the weekday is enough ("Tue"); inside 24h the day name
# stops discriminating, so hours ("13h"); inside 4h minutes start to matter
# ("3h14m"). A 7d window never runs long enough for the weekday to wrap, so
# the bare day name is unambiguous. Five-hour windows do not use this — they
# print a wall-clock time, which is sharper over so short a span.
format_reset() {
  local resetsAt=$1 nowEpoch=$2
  [ -z "$resetsAt" ] && return
  local secs=$(( resetsAt - nowEpoch ))
  if [ "$secs" -le 0 ]; then printf 'now'; return; fi
  if [ "$secs" -lt 14400 ]; then
    printf '%dh%02dm' "$(( secs / 3600 ))" "$(( (secs % 3600) / 60 ))"
  elif [ "$secs" -lt 86400 ]; then
    printf '%dh' "$(( secs / 3600 ))"
  else
    epoch_fmt "$resetsAt" %a
  fi
}

# Display path of $2 as seen from $1, both absolute.
# Same dir -> "."; descendant -> "./sub/dir"; otherwise the common-prefix
# walk emits one ".." per level left behind. Comparison is per path
# component, so /repos/foo never matches /repos/foo-bar.
relpath() {
  local from=${1%/} to=${2%/}
  [ "$to" = "$from" ] && { printf '.'; return; }
  case "$to" in
    "$from"/*) printf './%s' "${to#"$from"/}"; return ;;
  esac

  local -a fa ta
  IFS='/' read -ra fa <<< "$from"
  IFS='/' read -ra ta <<< "$to"

  local i=0
  while [ "$i" -lt "${#fa[@]}" ] && [ "$i" -lt "${#ta[@]}" ] \
    && [ "${fa[$i]}" = "${ta[$i]}" ]; do
    i=$((i + 1))
  done

  local ups="" j
  for ((j = i; j < ${#fa[@]}; j++)); do ups="../$ups"; done

  local rest
  rest=$(IFS=/; printf '%s' "${ta[*]:$i}")
  if [ -z "$rest" ]; then
    printf '%s' "${ups%/}"
  else
    printf '%s%s' "$ups" "$rest"
  fi
}

# ============================================================
# LINE 1: Model + Context.  LINES 2-3: one quota row per provider.
# ============================================================

IFS=$'\x1f' read -r ctx_filled ctx_color <<< "$(get_ctx_band "$cur_tokens")"
ctx_bar=$(render_ctx_bar "$ctx_filled" "$ctx_color")

line1="${ctx_bar} ${used_pct}% ($(format_tokens "$cur_tokens"))/$(format_tokens "$ctx_size")"

# A five-hour cell: bare percentage plus a wall-clock reset. Over so short a
# span the clock time is sharper than any countdown, and pace is meaningless.
# The percentage is right-aligned to $4, the width of the widest five-hour
# reading on screen, so the leading column of both provider rows lines up
# without padding to a width no reading actually needs.
cell_5h() {
  local glyph=$1 pct=$2 reset=$3 width=${4:-1}
  [ -n "$pct" ] || return
  local when=""
  [ -n "$reset" ] && when=" $(epoch_fmt "$reset" %H:%M)"
  printf '%s %*s%%%s' "$glyph" "$width" "$pct" "$when"
}

# A multi-day cell: actual/pace plus a scaled reset. A window with no reset
# time has no knowable pace, so it degrades to a bare percentage and no tail.
cell_7d() {
  local glyph=$1 pct=$2 reset=$3 winsecs=${4:-604800}
  [ -n "$pct" ] || return
  local when=""
  [ -n "$reset" ] && when=" ($(format_reset "$reset" "$now"))"
  printf '%s %s%s' "$glyph" \
    "$(format_paced_usage "$pct" "$reset" "$now" "$winsecs")" "$when"
}

# Join cells inside a single column. Only the five-hour column can hold more
# than one reading, and only if the plan ever exposes a Codex 5h beside Spark's.
row_join() {
  local row="" c
  for c in "$@"; do
    [ -n "$c" ] || continue
    if [ -n "$row" ]; then row="${row} ${SEP} ${c}"; else row=$c; fi
  done
  printf '%s' "$row"
}

# Visible width of a cell: color escapes occupy no columns, so they must not
# be counted when measuring for alignment. Glyphs are assumed single-width,
# the same assumption the workspace row already makes.
vis_len() {
  local bare
  bare=$(printf '%s' "$1" | sed $'s/\x1b\\[[0-9;]*m//g')
  printf '%s' "${#bare}"
}

# Render one provider row against the shared column widths in $colw. Cells are
# padded to their column so the same window lands at the same offset on every
# row. A column this provider has no window for is spanned by blanks, divider
# included: the following cells stay in their column without an empty divider
# implying a reading that does not exist. Padding stops at the row's last
# populated cell, so a row that ends early carries no trailing dead space.
render_row() {
  local prefix=$1; shift
  local cells=("$@")
  local n=${#cells[@]} i last=-1 row="" cell pad len
  for ((i = 0; i < n; i++)); do
    [ -n "${cells[$i]}" ] && last=$i
  done
  [ "$last" -lt 0 ] && return
  for ((i = 0; i <= last; i++)); do
    [ "${colw[$i]}" -eq 0 ] && continue
    cell=${cells[$i]}
    if [ "$i" -eq "$last" ]; then
      row="${row}${cell}"
    elif [ -z "$cell" ]; then
      row="${row}$(printf '%*s' "$(( colw[i] + 3 ))" '')"
    else
      len=$(vis_len "$cell")
      pad=$(( colw[i] - len ))
      [ "$pad" -gt 0 ] && cell="${cell}$(printf '%*s' "$pad" '')"
      row="${row}${cell} ${SEP} "
    fi
  done
  printf '%s%s' "$prefix" "$row"
}

# Rows 2-3 group by provider, one row each, so the same window sits in the same
# column on both and a cross-provider comparison is a vertical glance. Claude's
# windows come from the Claude Code payload, gap-filled from the omp usage
# cache; the Codex windows are known only to that cache.

# Collect the first limit for each Codex label, then render labels in a fixed
# provider order. A limit whose scope cannot identify a 5h or 7d window never
# reaches this list, so an unknown window is silent rather than becoming `cx`.
c5h_pct="" c5h_reset="" c5h_winsecs=""
c7d_pct="" c7d_reset="" c7d_winsecs=""
cs5h_pct="" cs5h_reset="" cs5h_winsecs=""
cs7d_pct="" cs7d_reset="" cs7d_winsecs=""
if [ -n "${ocodex_recs:-}" ]; then
  IFS=$'\x1e' read -ra codex_arr <<< "$ocodex_recs"
  for codex_rec in "${codex_arr[@]}"; do
    cx_label="" cx_pct="" cx_reset="" cx_winsecs=""
    IFS=$'\x1f' read -r cx_label cx_pct cx_reset cx_winsecs <<< "$codex_rec"
    [ -n "$cx_pct" ] || continue
    case "$cx_label" in
      c5h)
        [ -n "$c5h_pct" ] || {
          c5h_pct=$cx_pct; c5h_reset=$cx_reset; c5h_winsecs=$cx_winsecs
        }
        ;;
      c7d)
        [ -n "$c7d_pct" ] || {
          c7d_pct=$cx_pct; c7d_reset=$cx_reset; c7d_winsecs=$cx_winsecs
        }
        ;;
      cs5h)
        [ -n "$cs5h_pct" ] || {
          cs5h_pct=$cx_pct; cs5h_reset=$cx_reset; cs5h_winsecs=$cx_winsecs
        }
        ;;
      cs7d)
        [ -n "$cs7d_pct" ] || {
          cs7d_pct=$cx_pct; cs7d_reset=$cx_reset; cs7d_winsecs=$cx_winsecs
        }
        ;;
    esac
  done
fi

# Width of the five-hour readings, so the percentages inside that column align
# even before the column itself is padded: a fleet whose meters all read single
# digits gets no dead space, and one reading 100% widens the rest to match.
w5h=1
for pct5h in "$rl_5h_pct" "$c5h_pct" "$cs5h_pct"; do
  [ -n "$pct5h" ] && [ "${#pct5h}" -gt "$w5h" ] && w5h=${#pct5h}
done

# The columns, in order: five hours, the provider's own seven days, its variant
# tier's seven days, then Sonnet. Every row supplies a cell for each column,
# empty where that provider has no such window, so column N means the same
# thing on every row.
claude_cells=(
  "$(cell_5h "$G_5H" "$rl_5h_pct" "$rl_5h_reset" "$w5h")"
  "$(cell_7d "$G_7D" "$rl_7d_pct" "$rl_7d_reset")"
  "$(cell_7d "${G_FABLE} ${G_7D}" "$ofb_pct" "$ofb_rst")"
  "$(cell_7d "s${G_7D}" "$rl_s7d_pct" "$rl_s7d_reset")"
)

# Codex exposes no five-hour window of its own today, only Spark's, so the
# five-hour column normally carries the Spark reading. A Codex 5h cell is
# rendered ahead of it if one ever appears, rather than collected and dropped.
codex_cells=(
  "$(row_join \
     "$(cell_5h "$G_5H" "$c5h_pct" "$c5h_reset" "$w5h")" \
     "$(cell_5h "$G_SPARK5H" "$cs5h_pct" "$cs5h_reset" "$w5h")")"
  "$(cell_7d "$G_7D" "$c7d_pct" "$c7d_reset" "$c7d_winsecs")"
  "$(cell_7d "${G_SPARK} ${G_7D}" "$cs7d_pct" "$cs7d_reset" "$cs7d_winsecs")"
  ""
)

# Column width is the widest cell any row puts in it. A column no row fills
# collapses to zero and is skipped entirely rather than padded to nothing.
colw=()
for ci in "${!claude_cells[@]}"; do
  cw=$(vis_len "${claude_cells[$ci]}")
  cx=$(vis_len "${codex_cells[$ci]}")
  [ "$cx" -gt "$cw" ] && cw=$cx
  colw[$ci]=$cw
done

claude_row=$(render_row "${G_CLAUDE}  " "${claude_cells[@]}")
codex_row=$(render_row "${G_CODEX}  " "${codex_cells[@]}")

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
# WORKSPACE ROW: Workspace (starship-style) + Session ID
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
is_wt=false
wt_top=""
main_top=""

if [ -n "$git_dir" ] && [ -d "$git_dir" ]; then
  need_refresh=true

  if [ -f "$GIT_CACHE" ]; then
    IFS=$'\x1f' read -r cached_dir cached_branch cached_icons cached_time \
      cached_wt cached_wt_top cached_main_top < "$GIT_CACHE"
    if [ "$cached_dir" = "$git_dir" ] && [ -n "$cached_time" ] && [ $((gitNow - cached_time)) -le 5 ]; then
      git_branch="$cached_branch"
      git_icons="$cached_icons"
      is_git=true
      if [ "$cached_wt" = "true" ]; then
        is_wt=true
        wt_top="$cached_wt_top"
        main_top="$cached_main_top"
      fi
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

    # Linked worktrees carry a .git *file* pointing into the parent repo;
    # the main working tree has a .git directory. Submodules also carry a
    # .git file, so exclude them via show-superproject-working-tree — being
    # inside a submodule is not being inside a worktree. The common dir lives
    # in the main tree, so its parent is the repo's main checkout — the
    # anchor the worktree path is expressed against.
    wt_top=$(git -C "$git_dir" rev-parse --show-toplevel 2>/dev/null)
    super=$(git -C "$git_dir" rev-parse --show-superproject-working-tree 2>/dev/null)
    if [ -n "$wt_top" ] && [ -f "$wt_top/.git" ] && [ -z "$super" ]; then
      is_wt=true
      common=$(git -C "$git_dir" rev-parse --git-common-dir 2>/dev/null)
      case "$common" in
        "") ;;
        /*) ;;
        *) common="$git_dir/$common" ;;
      esac
      [ -n "$common" ] && main_top=$(cd "$common/.." 2>/dev/null && pwd)
    else
      wt_top=""
    fi

    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s' \
      "$git_dir" "$git_branch" "$git_icons" "$gitNow" "$is_wt" "$wt_top" "$main_top" \
      > "$GIT_CACHE"
  fi
fi

# --- Build workspace string ---
ws_part=""

if $is_git; then
  if $is_wt; then
    # Worktree session. Line 2 names the dir the session was registered to,
    # unless that dir is the worktree itself (session launched inside it) —
    # then the repo's main checkout is the more useful anchor, and the
    # worktree line below states where the worktree sits relative to it.
    ws_dir="$proj_dir"
    case "$proj_dir" in
      "$wt_top"|"$wt_top"/*) [ -n "$main_top" ] && ws_dir="$main_top" ;;
    esac
    case "$ws_dir" in
      "$HOME"|"$HOME"/*) ws_part="~${ws_dir:${#HOME}}" ;;
      *) ws_part="$ws_dir" ;;
    esac
  else
    ws_part="${proj_dir##*/}"
    [ -n "$git_branch" ] && ws_part="${ws_part} ${BRANCH} ${git_branch}"
  fi

  if [ -n "$git_icons" ]; then
    ws_part="${ws_part} [${git_icons}]"
  fi
else
  case "$proj_dir" in
    "$HOME"|"$HOME"/*) ws_part="~${proj_dir:${#HOME}}" ;;
    *) ws_part="$proj_dir" ;;
  esac
fi

# Working directory if different from project dir. Suppressed in worktree
# sessions: cwd is inside the worktree by definition there, so the worktree
# line below already states it and this would only restate it wrongly.
if ! $is_wt && [ -n "$cur_dir" ] && [ "$cur_dir" != "$proj_dir" ]; then
  rel_cwd="${cur_dir#"$proj_dir"/}"
  [ "$rel_cwd" = "$cur_dir" ] && rel_cwd="${cur_dir##*/}"
  ws_part="${ws_part} > ./${rel_cwd}"
fi

# --- Worktree line (own row; long paths are truncated by Claude Code,
#     never wrapped, so it never shares a row with the workspace) ---
wt_line=""
if $is_wt && [ -n "$wt_top" ]; then
  # Anchor on the repo's main checkout: stable no matter where the session
  # was launched, and it is the "git checkout perspective" of the worktree.
  wt_base="${main_top:-${proj_dir:-$cur_dir}}"
  wt_disp=$(relpath "$wt_base" "$wt_top")

  # A worktree under $HOME reads better as ~/... than as a ../ chain that
  # climbs back out through it — take whichever renders shorter. Match the
  # path component boundary: /home/id-other is not under /home/id.
  case "$wt_top" in
    "$HOME"|"$HOME"/*)
      wt_abs="~${wt_top:${#HOME}}"
      [ "${#wt_abs}" -lt "${#wt_disp}" ] && wt_disp="$wt_abs"
      ;;
  esac

  wt_line=" ${WTREE} ${wt_disp}"
fi

sid_part="| ${session_id}"

# --- Workspace width check and buffered output ---
# The split is by provider, not by terminal width: Claude Code's payload
# carries no width. A provider with no known window contributes no row.
quota_rows=$line1
[ -n "$claude_row" ] && quota_rows="${quota_rows}"$'\n'"$claude_row"
[ -n "$codex_row" ] && quota_rows="${quota_rows}"$'\n'"$codex_row"

total_len=$(( host_prefix_len + ${#ws_part} + 1 + ${#sid_part} ))

# Emit all rows in one final write so a pty never renders a partial footer.
if [ "$total_len" -le 90 ]; then
  out=$(printf '%s\n%s%s %s' "$quota_rows" "$host_prefix" "$ws_part" "$sid_part")
else
  out=$(printf '%s\n%s%s\n%s' "$quota_rows" "$host_prefix" "$ws_part" "$sid_part")
fi

if [ -n "$wt_line" ]; then
  printf '%s\n%s\n' "$out" "$wt_line"
else
  printf '%s\n' "$out"
fi
