# Migration notes

Every release with a breaking change gets a section here: what changed, how it shows, and what to do. A section can be there before its release is out, and then it lists what has changed on `main` so far. The [release notes](https://github.com/zeybek/obench/releases) list all changes, and [STABILITY.md](../STABILITY.md) says what counts as breaking.

## 0.4 to 0.5

### A comparison with too few processes decides nothing

With 2 or 3 processes a side, as from `--count 2`, `--count 3`, or `obench ab --rounds 2` or `3`, the interval that `compare` printed as the 95% interval of the change covered 67% or 90% (#92). It flagged unchanged code: on an M2, reports from `--count 2` flagged 117 of 555 comparisons of the examples against themselves. Such a comparison is now left undecided. It prints the range of the change with `too few for 95%`, counts as unchanged, and under `--fail-on-regression` the run ends with status 3 where it used to end with 0 or 1.

Run 4 or more processes on both sides: `--count 4` or more, and at least 4 rounds of `ab`, whose default is 6. A side with 2 or 3 processes still gets an interval against a larger one, 2 against 8 or more and 3 against 5 or more. In the API, `hodges_lehmann_shift` returns `ok = false` for these cases, `Baseline_Diff` has `too_few_samples`, and `Comparison_Summary` has `undecided`.

### `--instructions` refuses the flags it ignored

`--instructions` runs every benchmark alone under Cachegrind and only counts instructions. It used to accept `--fail-on-alloc-regression`, `--zero-alloc`, `--test`, `--md`, `--csv`, `--html`, and `--spall` and do nothing with them, so a job could look like it gated on allocations when it didn't (#102). These are usage errors now, with exit status 2. Take them off the `--instructions` command, and run the allocation gate, the `@zero_alloc` checks, and the other reports in a normal run next to it.

## 0.3 to 0.4

### A regression needs its whole interval above the threshold

A change used to count as a regression when the Mann-Whitney p-value was under 0.05 and the median moved by more than `--threshold`. Now the whole 95% confidence interval of the change has to lie above the threshold (#72). Gates fire less often on noise, but a real change close to the threshold can pass now: a 3% slowdown with p = 0.0013 whose interval runs from +1.5% to +4.6% failed a 2% gate in 0.3 and passes it in 0.4.

To catch changes that small, make the interval narrower rather than the threshold lower: run each side in several processes with `--count 5`, or both sides on one machine with `obench ab` (see [Gate a pull request on performance](how-to/ci-gate.md)). `compare` now prints the interval next to every change. In the API, `Baseline_Diff` has the interval as `shift_pct`, `shift_low_pct`, and `shift_high_pct`, and `is_regression`, `is_improvement`, and `is_significant` follow the new rule.

### A baseline that can't be compared exits with status 3

A baseline that holds none of a suite's benchmarks, was built with another optimization mode, OS, architecture, `-microarch`, or bounds-check setting, or counted allocations the other way used to fail a gate with exit status 1, like a regression. It now exits with 3 (#74), so a job can save the baseline again instead of failing. A baseline file that can't be read still exits with 1, so a misspelled path doesn't pass for a baseline to save again. A script that treats every status other than 0 as a failure keeps working. One that checks for exactly 1 has to handle 3 too.

In the API, these problems moved from `Suite.failed_io` to the new `Suite.failed_baseline`. A baseline file that can't be read still counts in `Suite.failed_io`. A program with its own `main` should exit with `obench.suite_exit_code(&s)` rather than 1, to give the same statuses as the CLI. `obench compare` now also fails a gate, with 3, when the two reports have no benchmark in common, which it used to pass.

### New and not breaking

Format 6 of the JSON report (#69) adds fields that older readers ignore. `--filter` also matches regular expressions now, and every name the old substring filter selected is still selected. `--count`, `obench ab`, `--instructions`, `--counters`, `--test`, `--html`, and the rest are new options.

## 0.2 to 0.3

### Allocations are counted outside the timed samples

Up to 0.2, obench counted allocations in every timed sample, so a benchmark that allocates also paid for the counting. 0.3 counts them in one more batch after the samples, which runs untimed (#20). Benchmarks that allocate look faster in 0.3 than in 0.2 although nothing changed: in `examples/allocators` on an M2, counting in every sample made `heap` 14% slower and `temp_allocator` 19% slower.

Reports from 0.2 are format version 3 and counted the old way. A regression gate in 0.3 against such a baseline fails with a warning when it has a benchmark that allocates, since their times can't be compared. Save the baseline again with 0.3, or run with `--timed-allocs` until you do.

A `Config` literal that leaves out `untimed_alloc_check = true` still counts in every timed sample, since the field's zero value is false. Add the field, or start from `default_config()`, which sets it.
