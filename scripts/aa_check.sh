#!/usr/bin/env bash
# A/A check: runs the same code several times with --count, compares every pair of reports,
# and fails when more than AA_MAX_PCT percent of the benchmark comparisons flag a change.
#
#   scripts/aa_check.sh [dir]   (default: examples)
#
# OBENCH (./bin/obench), AA_REPORTS (3), AA_COUNT (5 processes each) and AA_MAX_PCT (5) set
# the rest. With GITHUB_STEP_SUMMARY set, the result also goes to the job summary.
set -euo pipefail
OBENCH=${OBENCH:-./bin/obench}
target=${1:-examples}
reports=${AA_REPORTS:-3}
count=${AA_COUNT:-5}
max_pct=${AA_MAX_PCT:-5}
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

for i in $(seq 1 "$reports"); do
  echo "aa_check: report $i of $reports ($count processes)"
  "$OBENCH" "$target" --count "$count" -q --no-color --json "$work/r$i.json" > /dev/null
done

flagged=0
total=0
rows=""
for i in $(seq 1 "$reports"); do
  j=$((i + 1))
  while [ "$j" -le "$reports" ]; do
    summary="$("$OBENCH" compare "$work/r$i.json" "$work/r$j.json" --no-color | grep '^Summary')"
    read -r faster slower unchanged < <(echo "$summary" |
      sed -E 's/.*\(([0-9]+) faster, ([0-9]+) slower, ([0-9]+) unchanged\).*/\1 \2 \3/')
    flagged=$((flagged + faster + slower))
    total=$((total + faster + slower + unchanged))
    rows="$rows| $i vs $j | $faster | $slower | $unchanged |"$'\n'
    j=$((j + 1))
  done
done

verdict="passed"
if [ $((flagged * 100)) -gt $((max_pct * total)) ]; then
  verdict="failed"
fi
line="A/A: $flagged of $total benchmark comparisons flagged a change (at most $max_pct% may), $verdict"
echo "$line"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### A/A check"
    echo
    echo "$reports reports of \`$target\`, each from $count processes, compared pairwise."
    echo
    echo "| reports | faster | slower | unchanged |"
    echo "|:--|--:|--:|--:|"
    printf '%s' "$rows"
    echo
    echo "$line"
  } >> "$GITHUB_STEP_SUMMARY"
fi
[ "$verdict" = passed ]
