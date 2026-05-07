#!/bin/bash
# Run every tests/test_*.sh and aggregate exit codes.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fails=0
for f in "$DIR"/test_*.sh; do
  printf '\n=== %s ===\n' "$(basename "$f")"
  if ! bash "$f"; then
    fails=$((fails + 1))
  fi
done

if [ "$fails" -eq 0 ]; then
  printf '\nALL OK\n'
  exit 0
else
  printf '\n%d test file(s) had failures\n' "$fails"
  exit 1
fi
