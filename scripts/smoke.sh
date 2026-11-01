#!/usr/bin/env bash
# End-to-end checks for the obench CLI. Used by `make smoke` and CI.
# Usage: scripts/smoke.sh [path/to/obench]
set -euo pipefail

OBENCH="${1:-./bin/obench}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/obench-smoke.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cd "$ROOT"

fail() { echo "smoke: FAIL: $*" >&2; exit 1; }

# Git Bash on Windows: hand native paths to the (native) obench and odin executables.
native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}
WORK_N="$(native_path "$WORK")"
ROOT_N="$(native_path "$ROOT")"
step() { echo; echo "smoke: $*"; }

snapshot() { find examples -type f | LC_ALL=C sort; }
BEFORE="$(snapshot)"

step "usage errors exit with status 2"
set +e
"$OBENCH" --definitely-not-a-flag >/dev/null 2>&1; code=$?
set -e
[ "$code" -eq 2 ] || fail "expected exit 2 for an unknown flag, got $code"

step "list discovers the five example packages"
"$OBENCH" list examples | tee "$WORK/list.txt"
[ "$(grep -c "^Package " "$WORK/list.txt")" -eq 5 ] || fail "expected 5 packages"

step "run every example and merge the reports"
"$OBENCH" examples -n 8 -w 2 --no-color \
  --save-baseline "$WORK_N/base.json" --csv "$WORK_N/all.csv" --md "$WORK_N/all.md"
for suite in allocators_bench aos_vs_soa_bench parallel_bench sorting_bench "Slice vs Binary Search vs Map"; do
  grep -q "\"suite_name\": \"$suite\"" "$WORK/base.json" || fail "merged JSON is missing suite '$suite'"
done
[ "$(grep -c '"full_name"' "$WORK/base.json")" -eq 37 ] || fail "expected 37 benchmarks in the merged JSON"
[ "$(wc -l < "$WORK/all.csv" | tr -d ' ')" -eq 38 ] || fail "expected a header and 37 rows in the merged CSV"

step "comparing a report with itself passes the regression gate"
"$OBENCH" compare "$WORK_N/base.json" "$WORK_N/base.json" --fail-on-regression --no-color

step "a real slowdown is caught by --fail-on-regression"
mkdir -p "$WORK/regress"
cat > "$WORK/regress/regress_bench.odin" <<'ODIN'
package regress_bench

import obench "libs:obench"

WORK :: #config(WORK, 1000)

bench_loop :: proc(b: ^obench.Bencher) {
	for obench.step(b) {
		acc := 0
		for i in 0 ..< WORK {
			acc += obench.black_box(i)
		}
		_ = obench.black_box(acc)
	}
}
ODIN
"$OBENCH" "$WORK_N/regress" --collection "libs=$ROOT_N" -n 30 -w 20 --no-color --save-baseline "$WORK_N/fast.json"
set +e
"$OBENCH" "$WORK_N/regress" --collection "libs=$ROOT_N" --define WORK=10000 -n 30 -w 20 --no-color \
  --baseline "$WORK_N/fast.json" --fail-on-regression --json "$WORK_N/slow.json"
code=$?
set -e
[ "$code" -eq 1 ] || fail "expected exit 1 for a 10x slowdown, got $code"
set +e
"$OBENCH" compare "$WORK_N/fast.json" "$WORK_N/slow.json" --fail-on-regression --no-color; code=$?
set -e
[ "$code" -eq 1 ] || fail "expected compare to exit 1 for a 10x slowdown, got $code"

step "packages that share a name get suites of their own"
for dir in a b; do
  mkdir -p "$WORK/dup/$dir"
  cat > "$WORK/dup/$dir/dup_bench.odin" <<'ODIN'
package dup_bench

import obench "libs:obench"

bench_x :: proc(b: ^obench.Bencher) {
	for obench.step(b) {
		_ = obench.black_box(1)
	}
}
ODIN
done
"$OBENCH" "$WORK_N/dup" --collection "libs=$ROOT_N" -n 5 -w 2 --no-color --json "$WORK_N/dup.json"
for suite in "dup_bench (a)" "dup_bench (b)"; do
  grep -q "\"suite_name\": \"$suite\"" "$WORK/dup.json" || fail "merged JSON is missing suite '$suite'"
done

step "a one-suite baseline is not shared by several packages"
"$OBENCH" "$WORK_N/dup/a" --collection "libs=$ROOT_N" -n 5 -w 2 --no-color --json "$WORK_N/dup_a.json"
set +e
"$OBENCH" "$WORK_N/dup" --collection "libs=$ROOT_N" -n 5 -w 2 --no-color \
  --baseline "$WORK_N/dup_a.json" --fail-on-regression 2> "$WORK/dup_err.txt"; code=$?
set -e
[ "$code" -eq 1 ] || fail "expected exit 1 when no suite matches the baseline, got $code"
grep -q "nothing was compared" "$WORK/dup_err.txt" || fail "expected a 'nothing was compared' warning"

step "a benchmark package that does not parse fails the run"
mkdir -p "$WORK/parse/good" "$WORK/parse/bad"
cp "$WORK/dup/a/dup_bench.odin" "$WORK/parse/good/good_bench.odin"
printf 'package bad_bench\n\nbench_y :: proc(b: ^obench.Bencher {\n' > "$WORK/parse/bad/bad_bench.odin"
set +e
"$OBENCH" "$WORK_N/parse" --collection "libs=$ROOT_N" -n 5 -w 2 --no-color >/dev/null 2>&1; code=$?
set -e
[ "$code" -eq 1 ] || fail "expected exit 1 when a package does not parse, got $code"

step "a failed run does not promote an old report to --save-baseline"
mkdir -p "$WORK/stale"
cp "$WORK/dup/a/dup_bench.odin" "$WORK/stale/stale_bench.odin"
"$OBENCH" "$WORK_N/stale" --collection "libs=$ROOT_N" -n 5 -w 2 --no-color --json "$WORK_N/stale_a.json"
printf 'package dup_bench\n\nimport obench "libs:obench"\n\nbench_x :: proc(b: ^obench.Bencher) { not_declared() }\n' \
  > "$WORK/stale/stale_bench.odin"
set +e
"$OBENCH" "$WORK_N/stale" --collection "libs=$ROOT_N" -n 5 -w 2 --no-color \
  --json "$WORK_N/stale_a.json" --save-baseline "$WORK_N/stale_b.json" >/dev/null 2>&1; code=$?
set -e
[ "$code" -eq 1 ] || fail "expected exit 1 for a build failure, got $code"
[ ! -e "$WORK/stale_b.json" ] || fail "the old --json report was copied to --save-baseline"

step "nothing was written into the source tree"
AFTER="$(snapshot)"
[ "$BEFORE" = "$AFTER" ] || fail "files under examples/ changed: $(diff <(echo "$BEFORE") <(echo "$AFTER") || true)"

echo
echo "smoke: all checks passed"
