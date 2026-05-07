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
assert_match '^▓░░░ 5% \(50K\) / 1\.0M' "$stripped"
start_test "ctx-band: default has no yellow"; assert_no_match "${ESC}\\[33m" "$line1"
start_test "ctx-band: default has no red";    assert_no_match "${ESC}\\[31m" "$line1"
start_test "ctx-band: default has no magenta";assert_no_match "${ESC}\\[95m" "$line1"

start_test "ctx-band: yellow + 2 segments at exactly 100K"
out=$(invoke_statusline "$(default_payload '.context_window.used_percentage=10')")
line1=$(line_n 0 "$out"); stripped=$(printf '%s' "$line1" | strip_ansi)
assert_match '^▓▓░░ 10% \(100K\) / 1\.0M' "$stripped"
start_test "ctx-band: yellow ESC present at 100K"; assert_match "${ESC}\\[33m" "$line1"

start_test "ctx-band: red + 3 segments at exactly 200K"
out=$(invoke_statusline "$(default_payload '.context_window.used_percentage=20')")
line1=$(line_n 0 "$out"); stripped=$(printf '%s' "$line1" | strip_ansi)
assert_match '^▓▓▓░ 20% \(200K\) / 1\.0M' "$stripped"
start_test "ctx-band: red ESC present at 200K";    assert_match "${ESC}\\[31m" "$line1"
start_test "ctx-band: red is not yellow at 200K";  assert_no_match "${ESC}\\[33m" "$line1"

start_test "ctx-band: vivid magenta + 4 segments at exactly 350K"
out=$(invoke_statusline "$(default_payload '.context_window.used_percentage=35')")
line1=$(line_n 0 "$out"); stripped=$(printf '%s' "$line1" | strip_ansi)
assert_match '^▓▓▓▓ 35% \(350K\) / 1\.0M' "$stripped"
start_test "ctx-band: magenta ESC at 350K"; assert_match "${ESC}\\[95m" "$line1"

start_test "ctx-band: still magenta + 4 at 900K"
out=$(invoke_statusline "$(default_payload '.context_window.used_percentage=90')")
line1=$(line_n 0 "$out"); stripped=$(printf '%s' "$line1" | strip_ansi)
assert_match '^▓▓▓▓ 90% \(900K\) / 1\.0M' "$stripped"
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
assert_match '^▓░░░ 5% \(46K\) / 1\.0M' "$stripped"

start_test "ctx-band: current_usage crosses 100K → yellow even with low used_pct"
out=$(invoke_statusline "$(default_payload \
  '.context_window.used_percentage=10' \
  '.context_window.current_usage.input_tokens=120000')")
line1=$(line_n 0 "$out"); stripped=$(printf '%s' "$line1" | strip_ansi)
assert_match '^▓▓░░ 10% \(120K\) / 1\.0M' "$stripped"
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
# Describe: 7-segment 7d bar with halfway-cross thresholds
# ============================================================
# When ResetsAt = NOW + 168h, pace = 0 → no green buffer, total ▓ on line1
# = 1 (ctx default band) + N (7d bar fill). Subtract 1 to get bar fill.

assert_7d_filled() {
  local pct=$1 expected=$2
  local payload
  payload=$(default_payload \
    ".rate_limits.seven_day.used_percentage=$pct" \
    ".rate_limits.seven_day.resets_at=$((NOW + 168 * 3600))")
  local out line1 stripped total
  out=$(invoke_statusline "$payload")
  line1=$(line_n 0 "$out")
  stripped=$(printf '%s' "$line1" | strip_ansi)
  total=$(printf '%s' "$stripped" | grep -o '▓' | wc -l | tr -d ' ')
  local got=$(( total - 1 ))
  assert_eq "$expected" "$got" "7d filled for pct=$pct"
}

start_test "7d bar: pct 0 fills 0";   assert_7d_filled 0   0
start_test "7d bar: pct 7 fills 0";   assert_7d_filled 7   0
start_test "7d bar: pct 8 fills 1";   assert_7d_filled 8   1
start_test "7d bar: pct 21 fills 1";  assert_7d_filled 21  1
start_test "7d bar: pct 22 fills 2";  assert_7d_filled 22  2
start_test "7d bar: pct 41 fills 3";  assert_7d_filled 41  3
start_test "7d bar: pct 50 fills 4";  assert_7d_filled 50  4
start_test "7d bar: pct 92 fills 6";  assert_7d_filled 92  6
start_test "7d bar: pct 93 fills 7";  assert_7d_filled 93  7
start_test "7d bar: pct 100 fills 7"; assert_7d_filled 100 7

# ============================================================
# Describe: pace meter (numeric)
# ============================================================

start_test "pace ~25% when 126h remain"
out=$(invoke_statusline "$(default_payload \
  '.rate_limits.seven_day.used_percentage=0' \
  ".rate_limits.seven_day.resets_at=$((NOW + 126 * 3600))")")
stripped=$(line_n 0 "$out" | strip_ansi)
assert_match ' 0%/25% ' "$stripped"

start_test "pace = 0% just after a reset (168h remain)"
out=$(invoke_statusline "$(default_payload \
  '.rate_limits.seven_day.used_percentage=0' \
  ".rate_limits.seven_day.resets_at=$((NOW + 168 * 3600))")")
stripped=$(line_n 0 "$out" | strip_ansi)
assert_match ' 0%/0% ' "$stripped"

start_test "pace = 99% when 1h remains"
out=$(invoke_statusline "$(default_payload \
  '.rate_limits.seven_day.used_percentage=0' \
  ".rate_limits.seven_day.resets_at=$((NOW + 1 * 3600))")")
stripped=$(line_n 0 "$out" | strip_ansi)
assert_match ' 0%/99% ' "$stripped"

start_test "renders actual/pace numeric pair when both nonzero (41%/51%)"
out=$(invoke_statusline "$(default_payload \
  '.rate_limits.seven_day.used_percentage=41' \
  ".rate_limits.seven_day.resets_at=$((NOW + 82 * 3600))")")
stripped=$(line_n 0 "$out" | strip_ansi)
assert_match ' 41%/51% ' "$stripped"

# ============================================================
# Describe: green buffer shading on 7d bar
# ============================================================

start_test "green buffer between actual and tail when actual < pace"
# actual=41 → aFilled=3; pace=51 → pFilled=4; bufN=1 green segment.
out=$(invoke_statusline "$(default_payload \
  '.rate_limits.seven_day.used_percentage=41' \
  ".rate_limits.seven_day.resets_at=$((NOW + 82 * 3600))")")
line1=$(line_n 0 "$out")
pat="▓▓▓${ESC}\\[32m░+${ESC}\\[0m"
assert_match "$pat" "$line1"

start_test "no green when actual >= pace"
# actual=60 → aFilled=4; pace=51 → pFilled=4; bufN=0.
out=$(invoke_statusline "$(default_payload \
  '.rate_limits.seven_day.used_percentage=60' \
  ".rate_limits.seven_day.resets_at=$((NOW + 82 * 3600))")")
line1=$(line_n 0 "$out")
assert_no_match "${ESC}\\[32m" "$line1"

# ============================================================
# Describe: reset countdown
# ============================================================

start_test "(4d2h) when 98h remain"
out=$(invoke_statusline "$(default_payload \
  '.rate_limits.seven_day.used_percentage=41' \
  ".rate_limits.seven_day.resets_at=$((NOW + 98 * 3600))")")
stripped=$(line_n 0 "$out" | strip_ansi)
assert_match '\(4d2h\)[[:space:]]*$' "$stripped"

start_test "DOW shown (not HH:mm) when ≥24h remain"
out=$(invoke_statusline "$(default_payload \
  '.rate_limits.seven_day.used_percentage=41' \
  ".rate_limits.seven_day.resets_at=$((NOW + 98 * 3600))")")
stripped=$(line_n 0 "$out" | strip_ansi)
assert_match ' [0-9]{1,3}%/[0-9]{1,3}% (Mon|Tue|Wed|Thu|Fri|Sat|Sun) \([0-9]+d[0-9]+h\)[[:space:]]*$' "$stripped"

start_test "(1d0h) at exactly 24h"
out=$(invoke_statusline "$(default_payload \
  '.rate_limits.seven_day.used_percentage=41' \
  ".rate_limits.seven_day.resets_at=$((NOW + 24 * 3600))")")
stripped=$(line_n 0 "$out" | strip_ansi)
assert_match '\(1d0h\)[[:space:]]*$' "$stripped"

start_test "(3d4h) when 76h22m remain"
out=$(invoke_statusline "$(default_payload \
  '.rate_limits.seven_day.used_percentage=49' \
  ".rate_limits.seven_day.resets_at=$((NOW + 274920))")")
stripped=$(line_n 0 "$out" | strip_ansi)
assert_match '\(3d4h\)[[:space:]]*$' "$stripped"

start_test "(3h) and HH:mm slot when 3h15m remain"
out=$(invoke_statusline "$(default_payload \
  '.rate_limits.seven_day.used_percentage=41' \
  ".rate_limits.seven_day.resets_at=$((NOW + 3 * 3600 + 15 * 60))")")
stripped=$(line_n 0 "$out" | strip_ansi)
assert_match ' [0-9]{1,3}%/[0-9]{1,3}% [0-9]{1,2}:[0-9]{2} \(3h\)[[:space:]]*$' "$stripped"

start_test "(0h) when only 30 minutes remain"
out=$(invoke_statusline "$(default_payload \
  '.rate_limits.seven_day.used_percentage=95' \
  ".rate_limits.seven_day.resets_at=$((NOW + 30 * 60))")")
stripped=$(line_n 0 "$out" | strip_ansi)
assert_match '\(0h\)[[:space:]]*$' "$stripped"

# ============================================================
# Describe: graceful handling
# ============================================================

start_test "omits 5h and 7d when rate_limits absent"
out=$(invoke_statusline "$(default_payload)")
stripped=$(line_n 0 "$out" | strip_ansi)
assert_match '^▓░░░ 5% \(50K\) / 1\.0M[[:space:]]*$' "$stripped"
start_test "no ' 5h ' segment when rate_limits absent";  assert_no_match ' 5h '  "$stripped"
start_test "no ' 7d ' segment when rate_limits absent";  assert_no_match ' 7d '  "$stripped"
start_test "no ' s7d ' segment when rate_limits absent"; assert_no_match ' s7d ' "$stripped"

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
stripped=$(line_n 0 "$out" | strip_ansi)
assert_match ' s7d ' "$stripped"

start_test "s7d segment shows actual/pace pair"
out=$(invoke_statusline "$(default_payload \
  '.rate_limits.seven_day_sonnet.used_percentage=30' \
  ".rate_limits.seven_day_sonnet.resets_at=$((NOW + 168 * 3600))")")
stripped=$(line_n 0 "$out" | strip_ansi)
assert_match ' s7d [▓░]+ 30%/0%' "$stripped"

# ============================================================
# Extra: nested-shape sonnet under .seven_day.sonnet
# ============================================================

start_test "s7d also reads seven_day.sonnet (nested shape)"
out=$(invoke_statusline "$(default_payload \
  '.rate_limits.seven_day.sonnet.used_percentage=42' \
  ".rate_limits.seven_day.sonnet.resets_at=$((NOW + 168 * 3600))")")
stripped=$(line_n 0 "$out" | strip_ansi)
assert_match ' s7d [▓░]+ 42%/0%' "$stripped"

test_summary
