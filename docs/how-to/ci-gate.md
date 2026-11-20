# Gate a pull request on performance

The simplest gate saves a baseline on `main` and fails a branch that got slower:

```sh
obench --save-baseline main.json                    # on main
obench --baseline main.json --fail-on-regression    # on the branch
```

That works on a quiet machine, but one run is one process, and two processes running the same code differ by more than the samples inside one. On an M2, comparing four runs of `examples/lookup` with each other flagged 48 of 144 benchmark comparisons although nothing changed. The steps below make a gate that holds.

## Run each side in several processes

```sh
obench --count 5 --save-baseline main.json
obench --count 5 --baseline main.json --fail-on-regression
```

`--count 5` runs every package in five processes, each with a different memory layout, and keeps the median of each process. When both the baseline and the run come from at least two processes, the gate compares those medians, so it only fails on a change that holds across processes. The same four runs of `examples/lookup` with `--count 5` flagged none of the 144 comparisons. It takes five times as long. `--count` writes `--json`, `--save-baseline`, and `--html`, but not `--md`, `--csv`, or `--spall`.

## Run both sides on the same machine

A baseline saved by another job, or on another day, comes from a machine in another state. `obench ab` builds both trees and runs them on one machine, alternately and in a random order, so whatever drifts during the job affects both sides alike:

```sh
git worktree add ../main origin/main
obench ab ../main . --fail-on-regression
```

It runs 6 rounds by default (`--rounds`), each side once per round in its own process. Keep at least 6: with 4 or fewer, the interval of the change covers every difference between the two sides' processes, so it's too wide to flag anything but a large change. On an M2, `ab` of a package against itself measured +0.06%, and against a copy that did 10% more work, +10.47%, which failed the gate.

In GitHub Actions, the checkout needs the history of `main` for the worktree. A sketch, with obench already built or downloaded onto `PATH`:

```yaml
- uses: actions/checkout@v7
  with:
    fetch-depth: 0
- run: git worktree add ../main origin/main
- run: obench ab ../main . --fail-on-regression --md "$GITHUB_STEP_SUMMARY"
```

## Read the exit status

| Status | Meaning |
|--:|:--|
| 0 | passed |
| 1 | a benchmark failed or regressed, a file couldn't be written, or the build failed |
| 2 | a usage error, like an unknown option |
| 3 | the baseline can't be compared with this run, so save it again |

Status 3 means the baseline can't be read, holds none of the run's benchmarks, was built with another optimization mode, OS, architecture, `-microarch`, or bounds-check setting, or counted allocations the other way. A run that ends with 3 still writes `--save-baseline`, so a job can replace the old baseline instead of failing:

```sh
set +e
obench --count 5 --baseline main.json --fail-on-regression --save-baseline new.json
status=$?
set -e
if [ "$status" -eq 3 ]; then
  mv new.json main.json   # the old baseline can't be compared, so this run becomes the baseline
elif [ "$status" -ne 0 ]; then
  exit "$status"
fi
```

## Show the result on the pull request

`--md "$GITHUB_STEP_SUMMARY"` writes the comparison as Markdown, with a one-line verdict first and the table in a `<details>` block, which works for a job summary or a pull request comment. `--json` writes it with every benchmark's verdict, for a bot. Both write the comparison with `obench compare` and `obench ab`. In a plain run, `--md` and `--json` write the run's own report instead. `obench compare main.json pr.json` compares two saved reports without running anything, and `obench compare a1.json a2.json -- b1.json b2.json` combines several reports on each side first.

## Gate on numbers that don't change between runs

Allocation counts are exact, so `--fail-on-alloc-regression` makes a gate that holds even on a noisy shared runner. It fails when a benchmark allocates more per operation than in the baseline, heap or temp, count or bytes, with no threshold.

On Linux with Valgrind, `--instructions` counts the instructions per operation under Cachegrind, which gives the same count on every run:

```sh
obench --instructions --save-baseline instructions.json
obench --instructions --baseline instructions.json --fail-on-regression --threshold 1
```

It fails when a benchmark needs more than `--threshold` percent more instructions. The count includes the work between `pause` and `resume`, and parallel benchmarks and packages with their own `main` are skipped.

## Check that the benchmarks still work

For a job that should only catch a broken benchmark, `obench --test` runs each one once with one iteration, with its `@zero_alloc` and allocation checks, and measures nothing. It can't read or save a baseline.

## Know how often the gate cries wolf

This repository runs [`scripts/aa_check.sh`](../../scripts/aa_check.sh) every week: three reports of the examples from `--count 5`, compared pairwise, failing when more than 5% of the comparisons flag a change. It flagged 0 of 111 on an M2, and 1 of 111 in its first run on GitHub's ubuntu-latest. Copy it to measure the false-alarm rate of your own runner.
