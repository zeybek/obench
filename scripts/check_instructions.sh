#!/usr/bin/env bash
# Counts the instructions of two sorting benchmarks with --instructions twice and fails unless
# both runs give the same counts, and the second passes a gate against the first. Needs
# Valgrind (Linux).
set -euo pipefail
OBENCH=${OBENCH:-./bin/obench}
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

"$OBENCH" examples/sorting --instructions -f 'sort\[32\]' --json "$work/a.json"
"$OBENCH" examples/sorting --instructions -f 'sort\[32\]' --json "$work/b.json" \
  --baseline "$work/a.json" --threshold 0.001 --fail-on-regression
[ "$(grep -c '"instructions_per_op"' "$work/a.json")" -eq 2 ] || {
  echo "check_instructions: expected two counted benchmarks" >&2
  exit 1
}
diff <(grep '"instructions_per_op"' "$work/a.json") <(grep '"instructions_per_op"' "$work/b.json") || {
  echo "check_instructions: two runs counted different instructions" >&2
  exit 1
}
echo "check_instructions: both runs counted the same instructions"
