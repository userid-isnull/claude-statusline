#!/bin/bash
# Translation of tests/statusline.Tests.ps1 (Pester) into bash, plus extra
# coverage for sonnet s7d and the model:effort prefix that the PS1 suite
# didn't exercise. Run via tests/run.sh.

set -u
LC_ALL=${LC_ALL:-C.UTF-8}

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${DIR}/lib.sh"

ESC=$'\033'

# ------------------------------------------------------------------
# Convenience: build payloads with the same defaults the Pester
# helper used (UsedPct=5, CtxSize=1000000, ProjectDir='C:/tmp/proj',
# SessionId='test-session'). Override with extra jq exprs.
# ------------------------------------------------------------------
default_payload() {
  build_payload "$@" \
    '.context_window.used_percentage //= 5' \
    '.context_window.context_window_size //= 1000000' \
    '.session_id //= "test-session"' \
    '.workspace.project_dir //= "C:/tmp/proj"'
}

# Each section here mirrors a Pester `Describe` block.

# ============================================================
# Describe: context window bands
# ============================================================

start_test "ctx-band: default (no color), 1 segment, < 100K"
out=$(invoke_statusline "$(default_payload)")
line1=$(line_n 0 "$out")
stripped=$(printf '%s' "$line1" | strip_ansi)
assert_match '^▓░░░ 5% \(50K\)/1\.0M' "$stripped"
start_test "ctx-band: default has no yellow"; assert_no_match "${ESC}\\[33m" "$line1"
start_test "ctx-band: default has no red";    assert_no_match "${ESC}\\[31m" "$line1"
start_test "ctx-band: default has no magenta";assert_no_match "${ESC}\\[95m" "$line1"

start_test "ctx-band: yellow + 2 segments at exactly 100K"
out=$(invoke_statusline "$(default_payload '.context_window.used_percentage=10')")
line1=$(line_n 0 "$out"); stripped=$(printf '%s' "$line1" | strip_ansi)
assert_match '^▓▓░░ 10% \(100K\)/1\.0M' "$stripped"
start_test "ctx-band: yellow ESC present at 100K"; assert_match "${ESC}\\[33m" "$line1"

start_test "ctx-band: red + 3 segments at exactly 200K"
out=$(invoke_statusline "$(default_payload '.context_window.used_percentage=20')")
line1=$(line_n 0 "$out"); stripped=$(printf '%s' "$line1" | strip_ansi)
assert_match '^▓▓▓░ 20% \(200K\)/1\.0M' "$stripped"
start_test "ctx-band: red ESC present at 200K";    assert_match "${ESC}\\[31m" "$line1"
start_test "ctx-band: red is not yellow at 200K";  assert_no_match "${ESC}\\[33m" "$line1"

start_test "ctx-band: vivid magenta + 4 segments at exactly 350K"
out=$(invoke_statusline "$(default_payload '.context_window.used_percentage=35')")
line1=$(line_n 0 "$out"); stripped=$(printf '%s' "$line1" | strip_ansi)
assert_match '^▓▓▓▓ 35% \(350K\)/1\.0M' "$stripped"
start_test "ctx-band: magenta ESC at 350K"; assert_match "${ESC}\\[95m" "$line1"

start_test "ctx-band: still magenta + 4 at 900K"
out=$(invoke_statusline "$(default_payload '.context_window.used_percentage=90')")
line1=$(line_n 0 "$out"); stripped=$(printf '%s' "$line1" | strip_ansi)
assert_match '^▓▓▓▓ 90% \(900K\)/1\.0M' "$stripped"
start_test "ctx-band: magenta ESC at 900K"; assert_match "${ESC}\\[95m" "$line1"

start_test "ctx-band: uses exact current_usage sum (not pct estimate)"
# used_pct=5 of 1M would estimate 50K but current_usage sums to 46,727
# (6 + 160 + 1232 + 45329) → displays as (46K) and stays default-band.
out=$(invoke_statusline "$(default_payload \
  '.context_window.current_usage.input_tokens=6' \
  '.context_window.current_usage.output_tokens=160' \
  '.context_window.current_usage.cache_creation_input_tokens=1232' \
  '.context_window.current_usage.cache_read_input_tokens=45329')")
stripped=$(line_n 0 "$out" | strip_ansi)
assert_match '^▓░░░ 5% \(46K\)/1\.0M' "$stripped"

start_test "ctx-band: current_usage crosses 100K → yellow even with low used_pct"
out=$(invoke_statusline "$(default_payload \
  '.context_window.used_percentage=10' \
  '.context_window.current_usage.input_tokens=120000')")
line1=$(line_n 0 "$out"); stripped=$(printf '%s' "$line1" | strip_ansi)
assert_match '^▓▓░░ 10% \(120K\)/1\.0M' "$stripped"
start_test "ctx-band: yellow ESC when current_usage forces band up"
assert_match "${ESC}\\[33m" "$line1"

# ============================================================
# Describe: up/down tokens removed
# ============================================================

start_test "no ↑ glyph on Line 1"
out=$(invoke_statusline "$(default_payload \
  '.context_window.total_input_tokens=23000' \
  '.context_window.total_output_tokens=2000')")
line1=$(line_n 0 "$out")
assert_no_match '↑' "$line1"
start_test "no ↓ glyph on Line 1"; assert_no_match '↓' "$line1"


# ============================================================
# Describe: pace meter (numeric)
# ============================================================

start_test "pace ~25% when 126h remain"
out=$(invoke_statusline "$(default_payload \
  '.rate_limits.seven_day.used_percentage=0' \
  ".rate_limits.seven_day.resets_at=$((NOW + 126 * 3600))")")
stripped=$(provider_row "$G_CLAUDE_ROW" "$out" | strip_ansi)
assert_match ' 0%/25%' "$stripped"

start_test "pace = 0% just after a reset (168h remain)"
out=$(invoke_statusline "$(default_payload \
  '.rate_limits.seven_day.used_percentage=0' \
  ".rate_limits.seven_day.resets_at=$((NOW + 168 * 3600))")")
stripped=$(provider_row "$G_CLAUDE_ROW" "$out" | strip_ansi)
assert_match ' 0%/0%' "$stripped"

start_test "pace = 99% when 1h remains"
out=$(invoke_statusline "$(default_payload \
  '.rate_limits.seven_day.used_percentage=0' \
  ".rate_limits.seven_day.resets_at=$((NOW + 1 * 3600))")")
stripped=$(provider_row "$G_CLAUDE_ROW" "$out" | strip_ansi)
assert_match ' 0%/99%' "$stripped"

start_test "renders actual/pace numeric pair when both nonzero (41%/51%)"
out=$(invoke_statusline "$(default_payload \
  '.rate_limits.seven_day.used_percentage=41' \
  ".rate_limits.seven_day.resets_at=$((NOW + 82 * 3600))")")
stripped=$(provider_row "$G_CLAUDE_ROW" "$out" | strip_ansi)
assert_match ' 41%/51%' "$stripped"

# ============================================================
# Describe: paced quota percentage color
# ============================================================

start_test "paced actual is green when below pace"
out=$(invoke_statusline "$(default_payload \
  '.rate_limits.seven_day.used_percentage=41' \
  ".rate_limits.seven_day.resets_at=$((NOW + 82 * 3600))")")
line1=$(provider_row "$G_CLAUDE_ROW" "$out")
assert_match "${ESC}\\[32m41%${ESC}\\[0m/51%" "$line1"

start_test "paced actual is red when above pace"
out=$(invoke_statusline "$(default_payload \
  '.rate_limits.seven_day.used_percentage=60' \
  ".rate_limits.seven_day.resets_at=$((NOW + 82 * 3600))")")
line1=$(provider_row "$G_CLAUDE_ROW" "$out")
assert_match "${ESC}\\[31m60%${ESC}\\[0m/51%" "$line1"

start_test "paced actual is green at the exact pace boundary"
out=$(invoke_statusline "$(default_payload \
  '.rate_limits.seven_day.used_percentage=50' \
  ".rate_limits.seven_day.resets_at=$((NOW + 84 * 3600))")")
line1=$(provider_row "$G_CLAUDE_ROW" "$out")
assert_match "${ESC}\\[32m50%${ESC}\\[0m/50%" "$line1"

# A window with a percentage but no reset time has no knowable pace. It must
# still report the percentage rather than disappear: `omp usage --json` omits
# `resetsAt` on a window that has not been touched this period.
out=$(invoke_statusline "$(default_payload \
  '.rate_limits.seven_day.used_percentage=41')")
line1=$(provider_row "$G_CLAUDE_ROW" "$out")
start_test "7d without a reset keeps the percentage and drops the pace"
assert_match "${G_7D_T} 41%[[:space:]]*$" "$(printf '%s' "$line1" | strip_ansi)"
start_test "7d without a reset is uncolored"
assert_no_match "${ESC}\\[3[12]m" "$line1"

out=$(invoke_statusline "$(default_payload \
  '.rate_limits.seven_day_sonnet.used_percentage=33')")
start_test "s7d without a reset keeps the percentage and drops the pace"
assert_match "s${G_7D_T} 33%[[:space:]]*$" "$(provider_row "$G_CLAUDE_ROW" "$out" | strip_ansi)"

out=$(invoke_statusline "$(default_payload \
  '.rate_limits.five_hour.used_percentage=12')")
line1=$(provider_row "$G_CLAUDE_ROW" "$out")
stripped=$(printf '%s' "$line1" | strip_ansi)
start_test "5h percentage is uncolored and has no bar"
assert_match "${G_5H_T} 12%[[:space:]]*$" "$stripped"
start_test "5h percentage has no color escape"
assert_no_match "${ESC}\\[" "$line1"

# ============================================================
# Describe: reset format — day name beyond 24h, hours inside 24h,
# hours+minutes inside 4h. Day names are matched as a class so the
# suite does not depend on the runner's timezone.
# ============================================================

reset_token() {
  local secs=$1 out
  out=$(invoke_statusline "$(default_payload \
    '.rate_limits.seven_day.used_percentage=41' \
    ".rate_limits.seven_day.resets_at=$((NOW + secs))")")
  provider_row "$G_CLAUDE_ROW" "$out" | strip_ansi
}

start_test "day name when 98h remain"
assert_match '\((Mon|Tue|Wed|Thu|Fri|Sat|Sun)\)[[:space:]]*$' "$(reset_token $((98 * 3600)))"

start_test "day name at exactly 24h"
assert_match '\((Mon|Tue|Wed|Thu|Fri|Sat|Sun)\)[[:space:]]*$' "$(reset_token $((24 * 3600)))"

start_test "hours only when 13h remain"
assert_match '\(13h\)[[:space:]]*$' "$(reset_token $((13 * 3600)))"

start_test "hours only at exactly 4h"
assert_match '\(4h\)[[:space:]]*$' "$(reset_token $((4 * 3600)))"

start_test "hours and minutes when 3h15m remain"
assert_match '\(3h15m\)[[:space:]]*$' "$(reset_token $((3 * 3600 + 15 * 60)))"

start_test "minutes are zero-padded when 3h04m remain"
assert_match '\(3h04m\)[[:space:]]*$' "$(reset_token $((3 * 3600 + 4 * 60)))"

start_test "hours and minutes when only 30 minutes remain"
assert_match '\(0h30m\)[[:space:]]*$' "$(reset_token $((30 * 60)))"

start_test "a reset already past reads now"
assert_match '\(now\)[[:space:]]*$' "$(reset_token -60)"

start_test "no wall-clock time is used for a multi-day window"
assert_no_match '[0-9]{2}:[0-9]{2}' "$(reset_token $((3 * 3600 + 15 * 60)))"

# ============================================================
# Describe: graceful handling
# ============================================================

start_test "row 1 is model and context only when rate_limits absent"
out=$(invoke_statusline "$(default_payload)")
stripped=$(line_n 0 "$out" | strip_ansi)
assert_match '^▓░░░ 5% \(50K\)/1\.0M[[:space:]]*$' "$stripped"
start_test "no Claude quota row when rate_limits absent"
assert_eq '' "$(provider_row "$G_CLAUDE_ROW" "$out")" "Claude row without rate_limits"
start_test "no Codex quota row when rate_limits absent"
assert_eq '' "$(provider_row "$G_CODEX_ROW" "$out")" "Codex row without rate_limits"

# ============================================================
# Describe: Line 2 (workspace + session id)
# ============================================================

start_test "session id rendered somewhere in output"
out=$(invoke_statusline "$(default_payload '.session_id="abc-123-test"')")
stripped=$(printf '%s' "$out" | strip_ansi)
assert_match 'abc-123-test' "$stripped"

# ============================================================
# Extra: model + effort prefix (PS1 feature 1; not in Pester suite)
# ============================================================

start_test "model+effort prefix appears at line 1 start"
out=$(invoke_statusline "$(default_payload \
  '.model.display_name="Opus 4.7 (1M context)"' \
  '.effort.level="high"')")
stripped=$(line_n 0 "$out" | strip_ansi)
assert_match '^Opus:high ▓░░░ ' "$stripped"

start_test "model alone (no effort) prefixes line 1"
out=$(invoke_statusline "$(default_payload \
  '.model.display_name="Sonnet 4.6"')")
stripped=$(line_n 0 "$out" | strip_ansi)
assert_match '^Sonnet ▓░░░ ' "$stripped"

start_test "no model prefix when display_name absent"
out=$(invoke_statusline "$(default_payload)")
stripped=$(line_n 0 "$out" | strip_ansi)
assert_match '^▓░░░ ' "$stripped"

# ============================================================
# Extra: sonnet s7d segment (PS1 feature 8; not in Pester suite)
# ============================================================

start_test "s7d segment present when seven_day_sonnet payload set"
out=$(invoke_statusline "$(default_payload \
  '.rate_limits.seven_day_sonnet.used_percentage=30' \
  ".rate_limits.seven_day_sonnet.resets_at=$((NOW + 24 * 3600))")")
stripped=$(provider_row "$G_CLAUDE_ROW" "$out" | strip_ansi)
assert_match "s${G_7D_T} " "$stripped"

start_test "s7d segment shows actual/pace pair"
out=$(invoke_statusline "$(default_payload \
  '.rate_limits.seven_day_sonnet.used_percentage=30' \
  ".rate_limits.seven_day_sonnet.resets_at=$((NOW + 168 * 3600))")")
stripped=$(provider_row "$G_CLAUDE_ROW" "$out" | strip_ansi)
assert_match "s${G_7D_T} 30%/0%" "$stripped"

# ============================================================
# Extra: nested-shape sonnet under .seven_day.sonnet
# ============================================================

start_test "s7d also reads seven_day.sonnet (nested shape)"
out=$(invoke_statusline "$(default_payload \
  '.rate_limits.seven_day.sonnet.used_percentage=42' \
  ".rate_limits.seven_day.sonnet.resets_at=$((NOW + 168 * 3600))")")
stripped=$(provider_row "$G_CLAUDE_ROW" "$out" | strip_ansi)
assert_match "s${G_7D_T} 42%/0%" "$stripped"

# ============================================================
# Describe: SSH host prefix on Line 2 (issue #8)
# ============================================================
# STATUSLINE_SSH_PROBE_PROC=0 disables the /proc parent walk so the
# negative case is deterministic when tests run inside an SSH session.

invoke_statusline_with_env() {
  local payload="$1"; shift
  printf '%s' "$payload" | env \
    -u SSH_CONNECTION -u SSH_CLIENT -u SSH_TTY \
    STATUSLINE_NOW_EPOCH="$NOW" \
    STATUSLINE_SSH_PROBE_PROC=0 \
    "$@" \
    bash "$STATUSLINE"
}

ssh_user=$(whoami)
ssh_host=$(hostname -s)

start_test "no host prefix when no SSH env (proc probe disabled)"
out=$(invoke_statusline_with_env "$(default_payload)")
stripped=$(printf '%s' "$out" | strip_ansi)
assert_no_match "${ssh_user}@${ssh_host}" "$stripped"

start_test "host prefix appears when SSH_CONNECTION set"
out=$(invoke_statusline_with_env "$(default_payload)" \
  SSH_CONNECTION="10.0.0.1 22 10.0.0.2 22")
line2=$(line_n 1 "$out")
stripped=$(printf '%s' "$line2" | strip_ansi)
assert_match "${ssh_user}@${ssh_host}" "$stripped"

start_test "host prefix appears when only SSH_TTY set (zellij/tmux passthrough)"
out=$(invoke_statusline_with_env "$(default_payload)" SSH_TTY=/dev/pts/0)
line2=$(line_n 1 "$out")
stripped=$(printf '%s' "$line2" | strip_ansi)
assert_match "${ssh_user}@${ssh_host}" "$stripped"

start_test "host prefix appears when only SSH_CLIENT set"
out=$(invoke_statusline_with_env "$(default_payload)" \
  SSH_CLIENT="10.0.0.1 22 22")
line2=$(line_n 1 "$out")
stripped=$(printf '%s' "$line2" | strip_ansi)
assert_match "${ssh_user}@${ssh_host}" "$stripped"

test_summary
