#!/bin/bash
# Tests for the omp usage source (STATUSLINE_OMP_*): cache-driven f7d and
# Codex segments, gap-filling of 5h/7d/s7d from omp data, and Claude Code
# field precedence. All runs are hermetic — fixtures are injected through
# STATUSLINE_OMP_CACHE and the refresher is never invoked.

set -u
LC_ALL=${LC_ALL:-C.UTF-8}

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${DIR}/lib.sh"

ESC=$'\033'

# Fresh scratch dir per run: fixtures live here, TTL is pinned high so the
# script never tries to exec the real omp binary mid-test.
FIXTURE_DIR=$(mktemp -d)
OMP_ENV=(
  STATUSLINE_OMP_TTL=999999
  STATUSLINE_OMP_TIMEOUT=1
)
trap 'rm -rf "$FIXTURE_DIR"' EXIT

# Build an omp usage --json-shaped fixture. Window args are epoch-seconds;
# they are stored the way omp emits them (epoch milliseconds).
write_fixture() {
  local name=$1 five=$2 seven=$3 fable=$4 sonnet=$5 codex_used=${6:-} codex_reset_s=${7:-}
  {
    printf '{"reports":[{"provider":"anthropic","limits":['
    first=1
    emit() { [ "$first" = 0 ] && printf ','; first=0; printf '%s' "$1"; }
    [ -n "$five" ]   && emit "{\"id\":\"anthropic:5h\",\"amount\":{\"used\":$five},\"window\":{\"durationMs\":18000000,$([ -n "${five_rst:-}" ] && printf '"resetsAt":%s' "$((five_rst * 1000))" || true)}}"
    [ -n "$seven" ]  && emit "{\"id\":\"anthropic:7d\",\"amount\":{\"used\":$seven},\"window\":{\"durationMs\":604800000,\"resetsAt\":$((seven_rst * 1000))}}"
    [ -n "$fable" ]  && emit "{\"id\":\"anthropic:7d:fable\",\"amount\":{\"used\":$fable},\"window\":{\"durationMs\":604800000,\"resetsAt\":$((fable_rst * 1000))}}"
    [ -n "$sonnet" ] && emit "{\"id\":\"anthropic:7d:sonnet\",\"amount\":{\"used\":$sonnet},\"window\":{\"durationMs\":604800000,\"resetsAt\":$((sonnet_rst * 1000))}}"
    printf ']}'$'\n'
    if [ -n "$codex_used" ]; then
      printf ',{"provider":"openai-codex","limits":[{"id":"openai-codex:primary","amount":{"used":%s},"window":{"durationMs":604800000,"resetsAt":%s}}]}' \
        "$codex_used" "$((codex_reset_s * 1000))"
    fi
    printf ']}\n'
  } >"$FIXTURE_DIR/$name"
}

default_payload() {
  build_payload "$@" \
    '.context_window.used_percentage //= 5' \
    '.context_window.context_window_size //= 1000000' \
    '.session_id //= "omp-test-session"' \
    '.workspace.project_dir //= "/tmp/proj"'
}

# Run statusline.sh with the omp source enabled against a fixture cache.
run_with_fixture() {
  local fixture=$1 payload=$2
  printf '%s' "$payload" | env STATUSLINE_NOW_EPOCH="$NOW" STATUSLINE_OMP_DISABLE=0 \
    "${OMP_ENV[@]}" STATUSLINE_OMP_CACHE="$fixture" bash "$STATUSLINE"
}

# ============================================================
# Describe: f7d segment (Fable weekly, omp-only)
# ============================================================

# 58% used → 4 of 7 filled; reset 42h away → pace 75 → 5th segment green.
fable_rst=$((NOW + 42 * 3600))
seven_rst=$fable_rst
write_fixture fable.json "" "" 58 "" ""
out=$(run_with_fixture "$FIXTURE_DIR/fable.json" "$(default_payload)")
line1=$(line_n 0 "$out"); stripped=$(printf '%s' "$line1" | strip_ansi)

start_test "f7d: segment renders with actual/pace pair"
assert_match '\| f7d ▓▓▓▓░░░ 58%/75%' "$stripped"
start_test "f7d: pace buffer segment is green"
assert_match "^▓▓▓▓${ESC}\\[32m░" "$(printf '%s' "$line1" | sed 's/.*f7d //')"

# ============================================================
# Describe: Codex windows (omp-only, labeled by durationMs)
# ============================================================

codex_reset=$((NOW + 21 * 3600))   # pace = 87; used 100 fills all 7
write_fixture codex.json "" "" "" "" 100 "$codex_reset"
out=$(run_with_fixture "$FIXTURE_DIR/codex.json" "$(default_payload)")
stripped=$(printf '%s' "$(line_n 0 "$out")" | strip_ansi)

start_test "c7d: weekly codex window renders exhausted at 100%"
assert_match '\| c7d ▓▓▓▓▓▓▓ 100%/87%' "$stripped"

# ============================================================
# Describe: gap-fill — omp supplies what the payload lacks
# ============================================================

five_rst=$((NOW + 3 * 3600))
seven_rst=$((NOW + 84 * 3600))
write_fixture gaps.json 12 33 "" ""
payload=$(default_payload)   # no .rate_limits at all
out=$(run_with_fixture "$FIXTURE_DIR/gaps.json" "$payload")
stripped=$(printf '%s' "$(line_n 0 "$out")" | strip_ansi)

start_test "gap-fill: 5h renders from omp when payload lacks it"
assert_match '5h ░░░░ 12%' "$stripped"
start_test "gap-fill: 7d renders from omp when payload lacks it"
assert_match '7d ▓▓░░░░░ 33%/50%' "$stripped"

# ============================================================
# Describe: precedence — Claude Code fields win over the omp cache
# ============================================================

cc_reset=$((NOW + 100 * 3600))
write_fixture both.json 99 77 "" ""
payload=$(default_payload \
  ".rate_limits.seven_day.used_percentage=44" \
  ".rate_limits.seven_day.resets_at=$cc_reset")
out=$(run_with_fixture "$FIXTURE_DIR/both.json" "$payload")
stripped=$(printf '%s' "$(line_n 0 "$out")" | strip_ansi)

start_test "precedence: 7d uses the payload value, not omp's"
assert_match '7d [^|]*44%' "$stripped"
assert_no_match '7d [^|]*77%' "$stripped"

# ============================================================
# Describe: disabled / missing omp leaves output untouched
# ============================================================

out=$(printf '%s' "$(default_payload)" | STATUSLINE_NOW_EPOCH="$NOW" STATUSLINE_OMP_DISABLE=1 bash "$STATUSLINE")
start_test "disabled: no omp segments appear"
assert_no_match 'f7d|c7d|c5h' "$(printf '%s' "$out" | strip_ansi)"

test_summary
