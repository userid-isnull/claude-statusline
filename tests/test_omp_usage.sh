#!/bin/bash
# Tests for the omp usage source (STATUSLINE_OMP_*): cache-driven Fable and
# Codex segments, field-level Claude Code precedence, and payload tee gating.
# Cache fixtures keep every test hermetic: no test refreshes or spawns omp.

set -u
LC_ALL=${LC_ALL:-C.UTF-8}

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${DIR}/lib.sh"

ESC=$'\033'

EMPTY_CACHE=/tmp/statusline-omp-empty.json
ANTHROPIC_CACHE=/tmp/statusline-omp-anthropic.json
ALL_CODEX_CACHE=/tmp/statusline-omp-all-codex.json
SPARK_CACHE=/tmp/statusline-omp-spark.json
UNKNOWN_CODEX_CACHE=/tmp/statusline-omp-unknown-codex.json
GAPS_CACHE=/tmp/statusline-omp-gaps.json
NO_RESET_CACHE=/tmp/statusline-omp-no-reset.json
WIDTH_CACHE=/tmp/statusline-omp-width.json
GRID_CACHE=/tmp/statusline-omp-grid.json

# Each fixture is newer than the deterministic test clock and has a long TTL,
# so the statusline reads only the cache and never invokes omp.
write_fixture() {
  local path=$1 json=$2
  printf '%s\n' "$json" >"$path"
}

default_payload() {
  build_payload "$@" \
    '.context_window.used_percentage //= 5' \
    '.context_window.context_window_size //= 1000000' \
    '.session_id //= "omp-test-session"' \
    '.workspace.project_dir //= "/tmp/statusline-omp-project"'
}

run_with_fixture() {
  local fixture=$1 payload=$2
  printf '%s' "$payload" | env \
    STATUSLINE_NOW_EPOCH="$NOW" \
    STATUSLINE_OMP_DISABLE=0 \
    STATUSLINE_OMP_TTL=315360000 \
    STATUSLINE_OMP_TIMEOUT=1 \
    STATUSLINE_OMP_CACHE="$fixture" \
    STATUSLINE_PAYLOAD_TEE=0 \
    bash "$STATUSLINE"
}

run_without_omp() {
  local payload=$1
  printf '%s' "$payload" | env \
    STATUSLINE_NOW_EPOCH="$NOW" \
    STATUSLINE_OMP_DISABLE=1 \
    STATUSLINE_PAYLOAD_TEE=0 \
    bash "$STATUSLINE"
}

row_count() {
  printf '%s\n' "$1" | grep -c .
}

assert_file_absent() {
  local path=$1
  if [ ! -e "$path" ]; then
    pass
  else
    fail "expected no file at $path"
  fi
}

assert_file_present() {
  local path=$1
  if [ -e "$path" ]; then
    pass
  else
    fail "expected file at $path"
  fi
}

# The fixture shape mirrors `omp usage --json`: the only unit that renders is
# percent, and resetsAt stays in the source's epoch milliseconds.
limit_fixture() {
  local provider=$1 id=$2 used=$3 unit=$4 tier=$5 window_id=$6 duration_ms=$7 reset_s=$8
  jq -nc \
    --arg provider "$provider" \
    --arg id "$id" \
    --argjson used "$used" \
    --arg unit "$unit" \
    --arg tier "$tier" \
    --arg window_id "$window_id" \
    --argjson duration_ms "$duration_ms" \
    --argjson resets_at "$((reset_s * 1000))" \
    '{
      id: $id,
      label: $id,
      scope: {provider: $provider, windowId: $window_id, tier: $tier, modelId: "test-model", shared: false},
      window: {id: $window_id, label: $window_id, durationMs: $duration_ms, resetsAt: $resets_at},
      amount: {used: $used, limit: 100, unit: $unit}
    }'
}

payload=$(default_payload)
write_fixture "$EMPTY_CACHE" '{"reports":[]}'
out_without_omp=$(run_without_omp "$payload")
out_empty_cache=$(run_with_fixture "$EMPTY_CACHE" "$payload")

start_test "empty omp cache is byte-identical to no-cache rendering"
assert_eq "$out_without_omp" "$out_empty_cache" "empty cache output"
start_test "no Codex data emits no quota row"
assert_eq 2 "$(row_count "$out_empty_cache")" "row count without Codex"

# The source order is deliberately shuffled: the Codex row must always read
# c5h, cs5h, c7d, cs7d. The regular 5h limit uses scope.windowId rather
# than the id. Day names are matched as a class so the suite is TZ-independent.
fable_reset=$((NOW + 42 * 3600))
c5h_reset=$((NOW + 2 * 3600))
c7d_reset=$((NOW + 21 * 3600))
cs5h_reset=$((NOW + 3 * 3600))
cs7d_reset=$((NOW + 42 * 3600))
fable_limit=$(limit_fixture anthropic anthropic:7d:fable 58 percent fable 7d 604800000 "$fable_reset")
extra_limit=$(limit_fixture anthropic anthropic:extra 91 usd extra extra 0 "$fable_reset")
c5h_limit=$(limit_fixture openai-codex openai-codex:secondary 10 percent default 5h 18000000 "$c5h_reset")
c7d_limit=$(limit_fixture openai-codex openai-codex:primary 20 percent default 7d 604800000 "$c7d_reset")
cs5h_limit=$(limit_fixture openai-codex openai-codex:spark:primary 30 percent spark 5h 18000000 "$cs5h_reset")
cs7d_limit=$(limit_fixture openai-codex openai-codex:spark:secondary 40 percent spark 7d 604800000 "$cs7d_reset")

anthropic_fixture=$(jq -nc \
  --argjson fable "$fable_limit" \
  --argjson extra "$extra_limit" \
  '{reports:[{provider:"anthropic", limits:[$fable, $extra]}]}')
all_codex_fixture=$(jq -nc \
  --argjson fable "$fable_limit" \
  --argjson extra "$extra_limit" \
  --argjson c5h "$c5h_limit" \
  --argjson c7d "$c7d_limit" \
  --argjson cs5h "$cs5h_limit" \
  --argjson cs7d "$cs7d_limit" \
  '{reports:[
    {provider:"anthropic", limits:[$fable, $extra]},
    {provider:"openai-codex", limits:[$cs7d, $c7d, $cs5h, $c5h]}
  ]}')
write_fixture "$ANTHROPIC_CACHE" "$anthropic_fixture"
write_fixture "$ALL_CODEX_CACHE" "$all_codex_fixture"
out_anthropic=$(run_with_fixture "$ANTHROPIC_CACHE" "$payload")
out_all_codex=$(run_with_fixture "$ALL_CODEX_CACHE" "$payload")
line1_anthropic=$(line_n 0 "$out_anthropic")
line1_all_codex=$(line_n 0 "$out_all_codex")
claude_row=$(provider_row "$G_CLAUDE_ROW" "$out_all_codex" | strip_ansi)
codex_row=$(provider_row "$G_CODEX_ROW" "$out_all_codex" | strip_ansi)

start_test "row 1 never carries a quota window"
assert_no_match '58%|20%' "$(printf '%s' "$line1_all_codex" | strip_ansi)"
start_test "Codex data leaves row 1 byte-identical"
assert_eq "$line1_anthropic" "$line1_all_codex" "row 1 with Codex"
start_test "Codex row uses fixed c5h cs5h c7d cs7d order"
assert_match "^${G_CODEX_ROW}  ${G_5H_T} 10% [0-9]{2}:[0-9]{2} . ${G_SPARK5H_T} 30% [0-9]{2}:[0-9]{2} . ${G_7D_T} 20%/87% \(21h\) . ${G_SPARK_T} ${G_7D_T} 40%/75% \([A-Z][a-z]{2}\)$" "$codex_row"
start_test "Fable sits on the Claude row, not the Codex row"
assert_match "^${G_CLAUDE_ROW} +${G_FABLE_T} ${G_7D_T} 58%/75% \([A-Z][a-z]{2}\)$" "$claude_row"

raw_codex_row=$(provider_row "$G_CODEX_ROW" "$out_all_codex")
start_test "paced actual percentages use green when under pace"
assert_match "${ESC}\\[32m20%${ESC}\\[0m/87%.*${ESC}\\[32m40%${ESC}\\[0m/75%" "$raw_codex_row"
start_test "Codex data adds its own row before the workspace row"
assert_eq 4 "$(row_count "$out_all_codex")" "row count with Codex"
start_test "anthropic extra (USD) never renders"
assert_no_match 'extra|91%' "$(printf '%s' "$out_all_codex" | strip_ansi)"
start_test "a cache-only Anthropic window still gets its own row"
assert_eq 3 "$(row_count "$out_anthropic")" "row count with Fable only"
start_test "the Fable-only Claude row carries nothing else"
assert_match "^${G_CLAUDE_ROW}  ${G_FABLE_T} ${G_7D_T} 58%/75% \([A-Z][a-z]{2}\)$" "$(provider_row "$G_CLAUDE_ROW" "$out_anthropic" | strip_ansi)"

# Spark identity comes from scope.tier even when the id lacks :spark:.
spark_limit=$(limit_fixture openai-codex openai-codex:custom 25 percent spark 5h 18000000 "$cs5h_reset")
spark_fixture=$(jq -nc --argjson spark "$spark_limit" '{reports:[{provider:"openai-codex", limits:[$spark]}]}')
write_fixture "$SPARK_CACHE" "$spark_fixture"
out_spark=$(run_with_fixture "$SPARK_CACHE" "$payload")
spark_row=$(provider_row "$G_CODEX_ROW" "$out_spark" | strip_ansi)

start_test "spark-only Codex data carries the Spark 5h glyph"
assert_match "^${G_CODEX_ROW}  ${G_SPARK5H_T} 25% [0-9]{2}:[0-9]{2}$" "$spark_row"
start_test "spark-only Codex data does not use the plain 5h glyph"
assert_no_match "${G_5H_T}" "$spark_row"

# The five-hour column is padded to the widest reading on screen, across both
# provider rows. A fixed width would either waste a column when every meter
# reads single digits, or misalign the moment one reaches 100%.
width_payload=$(default_payload \
  '.rate_limits.five_hour.used_percentage=5' \
  ".rate_limits.five_hour.resets_at=$((NOW + 2 * 3600))")

narrow_limit=$(limit_fixture openai-codex openai-codex:spark:primary 7 percent spark 5h 18000000 "$cs5h_reset")
narrow_fixture=$(jq -nc --argjson s "$narrow_limit" '{reports:[{provider:"openai-codex", limits:[$s]}]}')
write_fixture "$WIDTH_CACHE" "$narrow_fixture"
out_narrow=$(run_with_fixture "$WIDTH_CACHE" "$width_payload")

start_test "single-digit readings on both rows get no padding"
assert_match "^${G_CLAUDE_ROW}  ${G_5H_T} 5% " "$(provider_row "$G_CLAUDE_ROW" "$out_narrow" | strip_ansi)"
start_test "single-digit Codex reading gets no padding either"
assert_match "^${G_CODEX_ROW}  ${G_SPARK5H_T} 7% " "$(provider_row "$G_CODEX_ROW" "$out_narrow" | strip_ansi)"

wide_limit=$(limit_fixture openai-codex openai-codex:spark:primary 100 percent spark 5h 18000000 "$cs5h_reset")
wide_fixture=$(jq -nc --argjson s "$wide_limit" '{reports:[{provider:"openai-codex", limits:[$s]}]}')
write_fixture "$WIDTH_CACHE" "$wide_fixture"
out_wide=$(run_with_fixture "$WIDTH_CACHE" "$width_payload")

start_test "a 100% reading widens the other row's five-hour cell to match"
assert_match "^${G_CLAUDE_ROW}  ${G_5H_T}   5% " "$(provider_row "$G_CLAUDE_ROW" "$out_wide" | strip_ansi)"
start_test "the 100% reading itself is not padded"
assert_match "^${G_CODEX_ROW}  ${G_SPARK5H_T} 100% " "$(provider_row "$G_CODEX_ROW" "$out_wide" | strip_ansi)"

# Every divider must sit at the same offset on both rows, whatever the cells
# contain. A short reading on one row is padded out so the next column starts
# level; an absent window is spanned by blanks rather than a hollow divider.
grid_fable=$(limit_fixture anthropic anthropic:7d:fable 2 percent fable 7d 604800000 "$fable_reset")
grid_c7d=$(limit_fixture openai-codex openai-codex:primary 100 percent default 7d 604800000 "$((NOW + 11700))")
grid_cs7d=$(limit_fixture openai-codex openai-codex:spark:secondary 4 percent spark 7d 604800000 "$cs7d_reset")
grid_fixture=$(jq -nc \
  --argjson f "$grid_fable" --argjson c "$grid_c7d" --argjson s "$grid_cs7d" \
  '{reports:[
    {provider:"anthropic", limits:[$f]},
    {provider:"openai-codex", limits:[$c, $s]}
  ]}')
write_fixture "$GRID_CACHE" "$grid_fixture"
grid_payload=$(default_payload \
  '.rate_limits.seven_day.used_percentage=43' \
  ".rate_limits.seven_day.resets_at=$((NOW + 400000))")
out_grid=$(run_with_fixture "$GRID_CACHE" "$grid_payload")

# Offsets of every divider on a row, as a space-separated list. Counted in
# characters, which is what the renderer pads in.
divider_cols() {
  local s=$1 i out=""
  for ((i = 0; i < ${#s}; i++)); do
    [ "${s:i:1}" = "$SEP_T" ] && out="${out}${i} "
  done
  printf '%s' "$out"
}
grid_claude=$(provider_row "$G_CLAUDE_ROW" "$out_grid" | strip_ansi)
grid_codex=$(provider_row "$G_CODEX_ROW" "$out_grid" | strip_ansi)

start_test "both provider rows put their dividers at identical offsets"
assert_eq "$(divider_cols "$grid_claude")" "$(divider_cols "$grid_codex")" "divider offsets"
start_test "the grid actually has dividers to align"
assert_match '[0-9]' "$(divider_cols "$grid_codex")"
start_test "a shorter cell is padded rather than shifting the next column"
assert_match "${G_7D_T} 43%/[0-9]+% \([A-Z][a-z]{2}\)  +${SEP_T}" "$grid_claude"

# No scope window, no window id, and an unknown duration must be skipped;
# rendering a cx placeholder would hide a future schema change.
unknown_limit=$(limit_fixture openai-codex openai-codex:unknown 19 percent default '' 3600000 "$c5h_reset")
unknown_fixture=$(jq -nc --argjson unknown "$unknown_limit" '{reports:[{provider:"openai-codex", limits:[$unknown]}]}')
write_fixture "$UNKNOWN_CODEX_CACHE" "$unknown_fixture"
out_unknown=$(run_with_fixture "$UNKNOWN_CODEX_CACHE" "$payload")

start_test "unknown Codex window is skipped without a cx placeholder"
assert_eq "$out_empty_cache" "$out_unknown" "unknown Codex output"

# Observed on xmsi: `omp usage --json` reports an untouched window with a used
# percentage and no `window.resetsAt` at all. Pace is unknowable there, but the
# percentage is still real and must not be dropped along with it.
no_reset_fable=$(jq -nc '{
  id: "anthropic:7d:fable",
  label: "Claude 7 Day (Fable)",
  scope: {provider: "anthropic", windowId: "7d", tier: "fable"},
  window: {id: "7d", label: "7 Day", durationMs: 604800000},
  amount: {used: 0, limit: 100, unit: "percent"}
}')
no_reset_codex=$(jq -nc '{
  id: "openai-codex:spark:primary",
  label: "5 hours (Spark)",
  scope: {provider: "openai-codex", windowId: "5h", tier: "spark"},
  window: {id: "5h", label: "5 hours", durationMs: 18000000},
  amount: {used: 7, limit: 100, unit: "percent"}
}')
no_reset_fixture=$(jq -nc \
  --argjson fable "$no_reset_fable" \
  --argjson codex "$no_reset_codex" \
  '{reports:[
    {provider:"anthropic", limits:[$fable]},
    {provider:"openai-codex", limits:[$codex]}
  ]}')
write_fixture "$NO_RESET_CACHE" "$no_reset_fixture"
out_no_reset=$(run_with_fixture "$NO_RESET_CACHE" "$payload")

start_test "a window with no reset keeps its percentage and drops the pace"
assert_match "^${G_CLAUDE_ROW} +${G_FABLE_T} ${G_7D_T} 0%$" "$(provider_row "$G_CLAUDE_ROW" "$out_no_reset" | strip_ansi)"
start_test "a 5h window with no reset keeps its percentage and drops the clock"
assert_match "^${G_CODEX_ROW}  ${G_SPARK5H_T} 7%$" "$(provider_row "$G_CODEX_ROW" "$out_no_reset" | strip_ansi)"
start_test "a window with no reset is uncolored"
assert_no_match "$(printf '\033')\\[3[12]m" "$(provider_row "$G_CLAUDE_ROW" "$out_no_reset")"

# Gap filling works per field: cache values fill only missing payload fields.
five_cache_reset=$((NOW + 3 * 3600))
seven_cache_reset=$((NOW + 84 * 3600))
sonnet_cache_reset=$((NOW + 42 * 3600))
five_limit=$(limit_fixture anthropic anthropic:5h 12 percent default 5h 18000000 "$five_cache_reset")
seven_limit=$(limit_fixture anthropic anthropic:7d 33 percent default 7d 604800000 "$seven_cache_reset")
sonnet_limit=$(limit_fixture anthropic anthropic:7d:sonnet 44 percent sonnet 7d 604800000 "$sonnet_cache_reset")
gaps_fixture=$(jq -nc \
  --argjson five "$five_limit" \
  --argjson seven "$seven_limit" \
  --argjson sonnet "$sonnet_limit" \
  '{reports:[{provider:"anthropic", limits:[$five, $seven, $sonnet]}]}')
write_fixture "$GAPS_CACHE" "$gaps_fixture"
out_gaps=$(run_with_fixture "$GAPS_CACHE" "$payload")
gaps_row=$(provider_row "$G_CLAUDE_ROW" "$out_gaps" | strip_ansi)

start_test "gap-fill supplies missing 5h fields"
assert_match "${G_5H_T} 12%" "$gaps_row"
start_test "gap-fill supplies missing 7d fields"
assert_match "${G_7D_T} 33%/50%" "$gaps_row"
start_test "gap-fill supplies missing s7d fields"
assert_match "s${G_7D_T} 44%/75%" "$gaps_row"

payload_seven_reset=$((NOW + 12 * 3600))
payload_sonnet_reset=$((NOW + 84 * 3600))
partial_payload=$(default_payload \
  '.rate_limits.five_hour.used_percentage=67' \
  '.rate_limits.seven_day.used_percentage=55' \
  ".rate_limits.seven_day.resets_at=$payload_seven_reset" \
  ".rate_limits.seven_day_sonnet.resets_at=$payload_sonnet_reset")
out_partial=$(run_with_fixture "$GAPS_CACHE" "$partial_payload")
partial_row=$(provider_row "$G_CLAUDE_ROW" "$out_partial" | strip_ansi)

start_test "gap-fill adds a missing reset without replacing payload 5h usage"
assert_match "${G_5H_T} 67% [0-9]{2}:[0-9]{2}" "$partial_row"
start_test "payload 7d values win over cached values"
assert_match "${G_7D_T} 55%/92%" "$partial_row"
start_test "payload s7d reset wins while cached usage fills its gap"
assert_match "s${G_7D_T} 44%/50%" "$partial_row"

# A non-Claude render such as the omp footer must not clobber shift-change's
# latest Claude payload. The default preserves the current two tee files.
rm -f /tmp/statusline-tee-disabled.json /tmp/statusline-tee-default.json /tmp/statusline-latest.json
tee_disabled_payload=$(default_payload '.session_id="tee-disabled"')
printf '%s' "$tee_disabled_payload" | env \
  STATUSLINE_NOW_EPOCH="$NOW" \
  STATUSLINE_OMP_DISABLE=1 \
  STATUSLINE_PAYLOAD_TEE=0 \
  bash "$STATUSLINE" >/dev/null

start_test "STATUSLINE_PAYLOAD_TEE=0 skips the per-session payload file"
assert_file_absent /tmp/statusline-tee-disabled.json
start_test "STATUSLINE_PAYLOAD_TEE=0 skips the latest payload file"
assert_file_absent /tmp/statusline-latest.json

tee_default_payload=$(default_payload '.session_id="tee-default"')
printf '%s' "$tee_default_payload" | env \
  STATUSLINE_NOW_EPOCH="$NOW" \
  STATUSLINE_OMP_DISABLE=1 \
  bash "$STATUSLINE" >/dev/null

start_test "default payload tee writes the per-session payload file"
assert_file_present /tmp/statusline-tee-default.json
start_test "default payload tee writes the latest payload file"
assert_file_present /tmp/statusline-latest.json

test_summary
