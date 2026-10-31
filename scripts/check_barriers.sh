#!/usr/bin/env bash
# Builds tests/barrier_probe to assembly at -o:speed and -o:aggressive and checks that
# black_box and keep_alive survive optimization. Used by `make check-barriers` and CI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/obench-barriers.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "check_barriers: FAIL: $*" >&2; exit 1; }

# Prints the instructions of procedure $2 in assembly file $1 (labels and directives removed).
body() {
  awk -v name="$2" '
    $0 ~ "^_?" name ":" { inside = 1; next }
    !inside { next }
    /^[^ \t].*:[ \t]*$/ { next }          # local labels (LBB0_1:, Lloh3:)
    $1 ~ /^\./ || NF == 0 { next }         # directives
    { print }
    $1 ~ /^ret/ { exit }
  ' "$1"
}

for opt in speed aggressive; do
  asm="$WORK/probe_$opt"
  odin build "$ROOT/tests/barrier_probe" -o:$opt -build-mode:asm -out:"$asm" >/dev/null
  files=("$asm"*)
  file="${files[0]}"

  const_fold="$(body "$file" probe_const_fold)"
  echo "$const_fold" | grep -q "41" || fail "-o:$opt: black_box(41) was folded away"$'\n'"$const_fold"

  kept="$(body "$file" probe_stores_kept)"
  echo "$kept" | grep -q "_escape" || fail "-o:$opt: keep_alive's call is missing"$'\n'"$kept"

  dropped="$(body "$file" probe_stores_dropped | grep -cv '^\s*ret' || true)"
  [ "$dropped" -le 1 ] || echo "check_barriers: note: -o:$opt kept stores even without a barrier"

  echo "check_barriers: -o:$opt ok ($(uname -m))"
done
