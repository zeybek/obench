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
"$OBENCH" examples -n 8 -w 2 --no-color --machine smoke-runner --html "$WORK_N/all.html" \
  --save-baseline "$WORK_N/base.json" --csv "$WORK_N/all.csv" --md "$WORK_N/all.md"
for suite in allocators_bench aos_vs_soa_bench parallel_bench sorting_bench "Slice vs Binary Search vs Map"; do
  grep -q "\"suite_name\": \"$suite\"" "$WORK/base.json" || fail "merged JSON is missing suite '$suite'"
done
[ "$(grep -c '"full_name"' "$WORK/base.json")" -eq 37 ] || fail "expected 37 benchmarks in the merged JSON"
[ "$(wc -l < "$WORK/all.csv" | tr -d ' ')" -eq 38 ] || fail "expected a header and 37 rows in the merged CSV"
[ "$(grep -o '<tr class="bench">' "$WORK/all.html" | wc -l | tr -d ' ')" -eq 37 ] ||
  fail "expected 37 benchmarks in the merged HTML report"

step "export converts the merged report for other tools"
for format in bmf gab gbench jsonl; do
  "$OBENCH" export --format "$format" "$WORK_N/base.json" > "$WORK/export.$format"
done
grep -q '"latency": {' "$WORK/export.bmf" || fail "the BMF export has no latency"
grep -q '"unit": "ns"' "$WORK/export.gab" || fail "the github-action-benchmark export has no times"
grep -q '"time_unit": "ns"' "$WORK/export.gbench" || fail "the Google Benchmark export has no times"
[ "$(wc -l < "$WORK/export.jsonl" | tr -d ' ')" -eq 37 ] || fail "expected one JSONL line per benchmark"

step "the report records the machine label and the commit"
grep -q '"label": "smoke-runner"' "$WORK/base.json" || fail "the report has no machine label"
if head="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"; then
  grep -q "\"commit\": \"$head\"" "$WORK/base.json" || fail "the report doesn't name commit $head"
fi

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
  --baseline "$WORK_N/fast.json" --fail-on-regression --json "$WORK_N/slow.json" --html "$WORK_N/slow.html"
code=$?
set -e
[ "$code" -eq 1 ] || fail "expected exit 1 for a 10x slowdown, got $code"
grep -q '<td class="slower">' "$WORK/slow.html" || fail "expected the HTML report to mark the slowdown"
set +e
"$OBENCH" compare "$WORK_N/fast.json" "$WORK_N/slow.json" --fail-on-regression --no-color; code=$?
set -e
[ "$code" -eq 1 ] || fail "expected compare to exit 1 for a 10x slowdown, got $code"

step "compare writes the comparison as Markdown and JSON"
"$OBENCH" compare "$WORK_N/fast.json" "$WORK_N/slow.json" --md "$WORK_N/cmp.md" --json "$WORK_N/cmp.json" \
  >/dev/null
grep -q '^\*\*obench compare:\*\* 1 slower' "$WORK/cmp.md" || fail "the Markdown comparison has no verdict line"
grep -q '"verdict": "slower"' "$WORK/cmp.json" || fail "the JSON comparison has no slower benchmark"

step "colors are off when the output isn't a terminal or NO_COLOR is set"
ESC="$(printf '\033')"
"$OBENCH" "$WORK_N/regress" --collection "libs=$ROOT_N" -n 5 -w 2 > "$WORK/run_plain.txt"
! grep -q "$ESC" "$WORK/run_plain.txt" || fail "a run wrote ANSI colors into a file"
"$OBENCH" compare "$WORK_N/fast.json" "$WORK_N/slow.json" > "$WORK/cmp_plain.txt" || true
! grep -q "$ESC" "$WORK/cmp_plain.txt" || fail "compare wrote ANSI colors into a file"
FORCE_COLOR=1 "$OBENCH" compare "$WORK_N/fast.json" "$WORK_N/slow.json" > "$WORK/cmp_forced.txt" || true
grep -q "$ESC" "$WORK/cmp_forced.txt" || fail "FORCE_COLOR=1 did not keep the colors of compare"
NO_COLOR=1 FORCE_COLOR=1 "$OBENCH" compare "$WORK_N/fast.json" "$WORK_N/slow.json" \
  > "$WORK/cmp_no_color.txt" || true
! grep -q "$ESC" "$WORK/cmp_no_color.txt" || fail "NO_COLOR did not turn off the colors of compare"

step "a baseline from an -o:none build exits 3 instead of looking faster"
"$OBENCH" "$WORK_N/regress" --collection "libs=$ROOT_N" -o none -n 10 -w 5 --no-color \
  --save-baseline "$WORK_N/none.json" >/dev/null
set +e
"$OBENCH" "$WORK_N/regress" --collection "libs=$ROOT_N" -n 10 -w 5 --no-color \
  --baseline "$WORK_N/none.json" --fail-on-regression >/dev/null 2> "$WORK/none_err.txt"; code=$?
set -e
[ "$code" -eq 3 ] || fail "expected exit 3 against a baseline from another -o mode, got $code"
grep -q "can't be compared" "$WORK/none_err.txt" || fail "expected a warning about the baseline's build"

step "a baseline file that can't be read exits 1, not 3"
set +e
"$OBENCH" examples/sorting -f 'sort\[32\]' -n 5 -w 2 --no-color --baseline "$WORK_N/mian.json" \
  --fail-on-regression >/dev/null 2> "$WORK/missing_err.txt"; code=$?
set -e
[ "$code" -eq 1 ] || fail "expected exit 1 for a baseline file that doesn't exist, got $code"
grep -q "could not read baseline" "$WORK/missing_err.txt" || fail "expected a warning about the baseline file"
set +e
"$OBENCH" examples/sorting -f 'sort\[32\]' -n 5 -w 2 --no-color --count 2 \
  --baseline "$WORK_N/mian.json" >/dev/null 2>&1; code=$?
set -e
[ "$code" -eq 1 ] || fail "expected --count to exit 1 for a baseline file that doesn't exist, got $code"

step "a baseline that counted allocations in every timed sample exits 3"
grep -q '"untimed_allocs": true' "$WORK/base.json" || fail "expected the default run to count allocations untimed"
"$OBENCH" examples/allocators -n 8 -w 2 --no-color --timed-allocs \
  --save-baseline "$WORK_N/timed.json" >/dev/null
grep -q '"untimed_allocs": false' "$WORK/timed.json" || fail "expected --timed-allocs in the report"
set +e
"$OBENCH" examples/allocators -n 8 -w 2 --no-color \
  --baseline "$WORK_N/timed.json" --fail-on-regression >/dev/null 2> "$WORK/timed_err.txt"; code=$?
set -e
[ "$code" -eq 3 ] || fail "expected exit 3 against a baseline counted in every timed sample, got $code"
grep -q "counted allocations in every timed sample" "$WORK/timed_err.txt" ||
  fail "expected a warning about how the baseline counted allocations"
set +e
"$OBENCH" compare "$WORK_N/timed.json" "$WORK_N/base.json" --fail-on-regression --no-color \
  > "$WORK/timed_cmp.txt"; code=$?
set -e
[ "$code" -eq 3 ] || fail "expected compare to exit 3 across the two ways of counting, got $code"
grep -q "counted allocations in every timed sample" "$WORK/timed_cmp.txt" ||
  fail "expected compare to warn about how the baseline counted allocations"

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
[ "$code" -eq 3 ] || fail "expected exit 3 when no suite matches the baseline, got $code"
grep -q "nothing was compared" "$WORK/dup_err.txt" || fail "expected a 'nothing was compared' warning"

step "a build that exits 0 without an executable (unknown --microarch) fails the run"
set +e
"$OBENCH" "$WORK_N/dup/a" --collection "libs=$ROOT_N" -n 5 -w 2 --no-color --microarch obench-no-such-cpu \
  --baseline "$WORK_N/dup_a.json" --fail-on-regression >/dev/null 2> "$WORK/march_err.txt"; code=$?
set -e
[ "$code" -eq 1 ] || fail "expected exit 1 for an unknown --microarch, got $code"
grep -q "did not build" "$WORK/march_err.txt" || fail "expected a 'did not build' error"

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

step "a library of another version than the CLI gets a warning"
mkdir -p "$WORK/oldlib"
cp -R "$ROOT/obench" "$WORK/oldlib/obench"
sed 's/^VERSION :: "[^"]*"/VERSION :: "0.0.1"/' "$ROOT/obench/doc.odin" > "$WORK/oldlib/obench/doc.odin"
"$OBENCH" "$WORK_N/dup/a" --collection "libs=$(native_path "$WORK/oldlib")" -n 5 -w 2 --no-color \
  >/dev/null 2> "$WORK/version_err.txt"
grep -q "but the obench library in .* is 0.0.1" "$WORK/version_err.txt" ||
  fail "expected a warning about the library's version"

step "--ols adds collections from ols.json only when requested and prints them"
mkdir -p "$WORK/ols_test/dep/helper" "$WORK/ols_test/bench"
cat > "$WORK/ols_test/ols.json" <<'JSON'
{"collections":[{"name":"dep","path":"./dep"}]}
JSON
cat > "$WORK/ols_test/dep/helper/helper.odin" <<'ODIN'
package helper

value :: proc() -> int { return 7 }
ODIN
cat > "$WORK/ols_test/bench/ols_bench.odin" <<'ODIN'
package ols_bench

import "dep:helper"
import obench "libs:obench"

@(custom_tag)
bench_ols :: proc(b: ^obench.Bencher) {
	for obench.step(b) {
		_ = obench.black_box(helper.value())
	}
}
ODIN
set +e
"$OBENCH" "$WORK_N/ols_test/bench" --collection "libs=$ROOT_N" --custom-attribute custom_tag \
  -n 5 -w 2 --no-color >/dev/null 2>&1; code=$?
set -e
[ "$code" -eq 1 ] || fail "expected exit 1 without --ols when importing an ols.json collection, got $code"
"$OBENCH" "$WORK_N/ols_test/bench" --collection "libs=$ROOT_N" --ols --custom-attribute custom_tag \
  -n 5 -w 2 --no-color >/dev/null 2> "$WORK/ols_err.txt"
grep -q "added -collection:dep=" "$WORK/ols_err.txt" || fail "expected --ols to print the added collection"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*|Windows_NT) ;;
  *)
    "$OBENCH" "$WORK_N/ols_test/bench" --collection "libs=$ROOT_N" --ols --custom-attribute custom_tag \
      --extra-linker-flags -lm --extra-linker-flags -lm -n 5 -w 2 --no-color >/dev/null
    ;;
esac

step "--test, --exact, -q and list --json"
"$OBENCH" examples/sorting --test --no-color > "$WORK/test_mode.txt"
grep -q "note: --test ran every benchmark once" "$WORK/test_mode.txt" || fail "expected the --test note"
grep -q "PASS: 6 benchmark(s)" "$WORK/test_mode.txt" || fail "expected --test to run all 6 sorting benchmarks"
"$OBENCH" examples/sorting --exact 'in_place_sort::slice_sort[128]' -n 5 -w 2 -q --no-color \
  --json "$WORK_N/exact.json" > "$WORK/exact.txt"
[ "$(grep -c '"full_name"' "$WORK/exact.json")" -eq 1 ] || fail "expected --exact to run one benchmark"
[ "$(wc -l < "$WORK/exact.txt" | tr -d ' ')" -le 2 ] || fail "expected -q to print only the summary"
"$OBENCH" list examples/sorting --json > "$WORK/list.json"
grep -q '"in_place_sort::slice_sort\[128\]"' "$WORK/list.json" || fail "expected full names in list --json"

step "the empty loop, the machine fields, and a baseline from another CPU"
"$OBENCH" examples/sorting -n 5 -w 2 --no-color --json "$WORK_N/cpu_a.json" > "$WORK/cpu_a.txt"
grep -q ", empty loop " "$WORK/cpu_a.txt" || fail "expected the empty loop in the header"
grep -q '"empty_loop_ns": [0-9]' "$WORK/cpu_a.json" || fail "expected clock.empty_loop_ns in the report"
grep -q '"effective_samples": ' "$WORK/cpu_a.json" || fail "expected effective_samples in the report"
sed 's/"cpu": "[^"]*"/"cpu": "Another CPU"/' "$WORK/cpu_a.json" > "$WORK/cpu_b.json"
"$OBENCH" examples/sorting -n 5 -w 2 --no-color --baseline "$WORK_N/cpu_b.json" >/dev/null 2> "$WORK/cpu_err.txt"
grep -q "was measured on Another CPU" "$WORK/cpu_err.txt" || fail "expected a warning about the baseline's CPU"

step "--count runs a package in several processes and combines their reports"
"$OBENCH" examples/sorting --count 3 -n 5 -w 2 --no-color --json "$WORK_N/count.json" > "$WORK/count.txt"
grep -q "sorting_bench over 3 processes" "$WORK/count.txt" || fail "expected the combined table of 3 processes"
grep -q '"processes": 3' "$WORK/count.json" || fail "expected processes in the combined report"
grep -q '"process_medians_ns"' "$WORK/count.json" || fail "expected the process medians in the report"
set +e
"$OBENCH" examples/sorting --count 3 -n 5 -w 2 --no-color --baseline "$WORK_N/count.json" \
  --fail-on-regression > "$WORK/count_cmp.txt"; code=$?
set -e
[ "$code" -le 1 ] || fail "expected --count against its own baseline to compare, got exit $code"
grep -q "matched" "$WORK/count_cmp.txt" || fail "expected --count to compare with the baseline"
"$OBENCH" "$WORK_N/regress" --collection "libs=$ROOT_N" --define WORK=1000 -n 10 -w 5 --no-color \
  --count 3 --json "$WORK_N/fast3.json" >/dev/null
set +e
"$OBENCH" "$WORK_N/regress" --collection "libs=$ROOT_N" --define WORK=10000 -n 10 -w 5 --no-color \
  --count 3 --baseline "$WORK_N/fast3.json" --fail-on-regression >/dev/null; code=$?
set -e
[ "$code" -eq 1 ] || fail "expected --count to catch a 10x slowdown, got exit $code"

step "compare combines several reports per side, and ab alternates two trees"
"$OBENCH" compare "$WORK_N/count.json" "$WORK_N/count.json" -- "$WORK_N/count.json" --no-color \
  --fail-on-regression > "$WORK/sides.txt"
grep -q "count.json [^ ]*count.json vs" "$WORK/sides.txt" || fail "expected both reports of the old side in the header"
for side in ab_fast ab_slow; do
  mkdir -p "$WORK/$side/regress"
  cp "$WORK/regress/regress_bench.odin" "$WORK/$side/regress/"
done
sed 's/#config(WORK, 1000)/10000/' "$WORK/regress/regress_bench.odin" > "$WORK/ab_slow/regress/regress_bench.odin"
set +e
"$OBENCH" ab "$WORK_N/ab_fast" "$WORK_N/ab_slow" --collection "libs=$ROOT_N" -n 10 -w 20 --no-color \
  --fail-on-regression > "$WORK/ab.txt"; code=$?
set -e
[ "$code" -eq 1 ] || fail "expected ab to catch a 10x slowdown, got exit $code"
grep -q "round 6 of 6" "$WORK/ab.txt" || fail "expected 6 rounds by default"

step "nothing was written into the source tree"
AFTER="$(snapshot)"
[ "$BEFORE" = "$AFTER" ] || fail "files under examples/ changed: $(diff <(echo "$BEFORE") <(echo "$AFTER") || true)"

echo
echo "smoke: all checks passed"
