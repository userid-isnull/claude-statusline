# Test scaffolding for statusline.sh
# Source this from each test_*.sh file. No external deps beyond bash, jq, sed —
# all of which statusline.sh already requires.

# Resolve the repo root (parent of tests/) regardless of cwd.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
STATUSLINE="${REPO_DIR}/statusline.sh"

# Fixed reference epoch matching the Pester suite (1747000000 = 2025-05-12 04:46:40 UTC).
# Lets pace/countdown calculations be deterministic across hosts.
NOW=1747000000

# Pass/fail accounting. Each test file sources lib.sh, runs assertions,
# then calls test_summary at exit; the runner sums exit codes.
PASS=0
FAIL=0
CURRENT_TEST=""

start_test() {
  CURRENT_TEST="$1"
}

pass() {
  PASS=$((PASS + 1))
  printf '  \033[32mok\033[0m   %s\n' "$CURRENT_TEST"
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  \033[31mFAIL\033[0m %s\n' "$CURRENT_TEST"
  printf '       %s\n' "$1"
  if [ -n "${2:-}" ]; then
    printf '       output was:\n'
    printf '%s\n' "$2" | sed 's/^/         /'
  fi
}

test_summary() {
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
}

# Strip ANSI SGR sequences. Used so visual layout assertions don't fight color.
strip_ansi() {
  sed $'s/\x1b\\[[0-9;]*m//g'
}

# Build a JSON payload with jq -n. Accepts a sequence of jq path=value pairs.
# Values must be jq expressions: strings need quoting, numbers don't.
# Example:
#   build_payload \
#     '.context_window.used_percentage=5' \
#     '.context_window.context_window_size=1000000' \
#     '.session_id="test-session"' \
#     '.workspace.project_dir="C:/tmp/proj"'
build_payload() {
  local args=()
  local p
  for p in "$@"; do
    args+=("$p")
  done
  local expr=""
  local first=1
  for p in "${args[@]}"; do
    if [ "$first" -eq 1 ]; then
      expr="$p"
      first=0
    else
      expr="$expr | $p"
    fi
  done
  if [ -z "$expr" ]; then
    expr="."
  fi
  jq -nc "{} | $expr"
}

# Run statusline.sh with the given JSON payload on stdin. Echoes stdout.
# STATUSLINE_NOW_EPOCH overrides the system clock so pace tests are deterministic.
invoke_statusline() {
  local payload="$1"
  printf '%s' "$payload" | STATUSLINE_NOW_EPOCH="$NOW" bash "$STATUSLINE"
}

# Convenience: extract the Nth output line (0-based) from a captured stdout.
line_n() {
  local idx="$1" out="$2"
  printf '%s' "$out" | sed -n "$((idx + 1))p"
}

# Assert that $haystack matches the regex $pattern (POSIX ERE via grep -E).
# On failure, prints a diagnostic with the haystack.
assert_match() {
  local pattern="$1" haystack="$2"
  if printf '%s' "$haystack" | grep -Eq "$pattern"; then
    pass
  else
    fail "expected match: $pattern" "$haystack"
  fi
}

assert_no_match() {
  local pattern="$1" haystack="$2"
  if printf '%s' "$haystack" | grep -Eq "$pattern"; then
    fail "expected NO match: $pattern" "$haystack"
  else
    pass
  fi
}

# Count occurrences of a single character in a string. Used for "how many ▓
# segments are in this bar" assertions.
count_char() {
  local needle="$1" hay="$2"
  printf '%s' "$hay" | awk -v n="$needle" '{ for (i=1;i<=length($0);i++) if (substr($0,i,1)==n) c++ } END { print c+0 }'
}

assert_eq() {
  local expected="$1" actual="$2" label="${3:-equality}"
  if [ "$expected" = "$actual" ]; then
    pass
  else
    fail "$label: expected '$expected', got '$actual'"
  fi
}
