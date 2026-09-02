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

# The source order is deliberately shuffled: the cache row must always read
# f7d, c5h, c7d, cs5h, cs7d. The regular 5h limit uses scope.windowId rather
# than the id.
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
codex_row=$(line_n 1 "$out_all_codex" | strip_ansi)

start_test "row 1 never carries a cache-only window"
assert_no_match 'f7d' "$(printf '%s' "$line1_all_codex" | strip_ansi)"
start_test "Codex data leaves row 1 byte-identical"
assert_eq "$line1_anthropic" "$line1_all_codex" "row 1 with Codex"
start_test "cache row uses fixed f7d c5h c7d cs5h cs7d order"
assert_match '^f7d 58%/75% \| c5h 10%/60% \| c7d 20%/87% \| cs5h 30%/40% \| cs7d 40%/75%$' "$codex_row"

raw_cache_row=$(line_n 1 "$out_all_codex")
start_test "cache paced actual percentages use green when under pace"
assert_match "${ESC}\\[32m58%${ESC}\\[0m/75%.*${ESC}\\[32m10%${ESC}\\[0m/60%.*${ESC}\\[32m20%${ESC}\\[0m/87%.*${ESC}\\[32m30%${ESC}\\[0m/40%.*${ESC}\\[32m40%${ESC}\\[0m/75%" "$raw_cache_row"
start_test "Codex data adds exactly one row before the workspace row"
assert_eq 3 "$(row_count "$out_all_codex")" "row count with Codex"
start_test "anthropic extra (USD) never renders"
assert_no_match 'extra|91%' "$(printf '%s' "$out_all_codex" | strip_ansi)"
start_test "a cache-only Anthropic window still gets its own row"
assert_eq 3 "$(row_count "$out_anthropic")" "row count with Fable only"
start_test "the Fable-only cache row carries nothing else"
assert_eq 'f7d 58%/75%' "$(line_n 1 "$out_anthropic" | strip_ansi)" "Fable-only cache row"

# Spark identity comes from scope.tier even when the id lacks :spark:.
spark_limit=$(limit_fixture openai-codex openai-codex:custom 25 percent spark 5h 18000000 "$cs5h_reset")
spark_fixture=$(jq -nc --argjson spark "$spark_limit" '{reports:[{provider:"openai-codex", limits:[$spark]}]}')
write_fixture "$SPARK_CACHE" "$spark_fixture"
out_spark=$(run_with_fixture "$SPARK_CACHE" "$payload")
spark_row=$(line_n 1 "$out_spark" | strip_ansi)

start_test "spark-only Codex data is visibly labeled cs5h"
assert_match '^cs5h 25%/40%$' "$spark_row"
start_test "spark-only Codex data does not collapse to c5h"
assert_no_match '^c5h ' "$spark_row"

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
no_reset_row=$(line_n 1 "$out_no_reset" | strip_ansi)

start_test "a window with no reset keeps its percentage and drops the pace"
assert_eq 'f7d 0% | cs5h 7%' "$no_reset_row" "no-reset cache row"
start_test "a window with no reset is uncolored"
assert_no_match "$(printf '\033')\\[3[12]m" "$(line_n 1 "$out_no_reset")"

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
gaps_row=$(line_n 0 "$out_gaps" | strip_ansi)

start_test "gap-fill supplies missing 5h fields"
assert_match '5h 12%' "$gaps_row"
start_test "gap-fill supplies missing 7d fields"
assert_match '7d 33%/50%' "$gaps_row"
start_test "gap-fill supplies missing s7d fields"
assert_match 's7d 44%/75%' "$gaps_row"

payload_seven_reset=$((NOW + 12 * 3600))
payload_sonnet_reset=$((NOW + 84 * 3600))
partial_payload=$(default_payload \
  '.rate_limits.five_hour.used_percentage=67' \
  '.rate_limits.seven_day.used_percentage=55' \
  ".rate_limits.seven_day.resets_at=$payload_seven_reset" \
  ".rate_limits.seven_day_sonnet.resets_at=$payload_sonnet_reset")
out_partial=$(run_with_fixture "$GAPS_CACHE" "$partial_payload")
partial_row=$(line_n 0 "$out_partial" | strip_ansi)

start_test "gap-fill adds a missing reset without replacing payload 5h usage"
assert_match '5h [^|]*67% [0-9]{2}:[0-9]{2}' "$partial_row"
start_test "payload 7d values win over cached values"
assert_match '7d [^|]*55%/92%' "$partial_row"
start_test "payload s7d reset wins while cached usage fills its gap"
assert_match 's7d [^|]*44%/50%' "$partial_row"

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
