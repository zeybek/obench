# Migration notes

Every release with a breaking change gets a section here: what changed, how it shows, and what to do. The [release notes](https://github.com/zeybek/obench/releases) list all changes, and [STABILITY.md](../STABILITY.md) says what counts as breaking.

## 0.3 to 0.4

0.4 isn't released yet. These are the breaking changes on `main` since 0.3.0.

### A regression needs its whole interval above the threshold

A change used to count as a regression when the Mann-Whitney p-value was under 0.05 and the median moved by more than `--threshold`. Now the whole 95% confidence interval of the change has to lie above the threshold (#72). Gates fire less often on noise, but a real change close to the threshold can pass now: a 3% slowdown with p = 0.0013 whose interval runs from +1.5% to +4.6% failed a 2% gate in 0.3 and passes it in 0.4.

To catch changes that small, make the interval narrower rather than the threshold lower: run each side in several processes with `--count 5`, or both sides on one machine with `obench ab` (see [Gate a pull request on performance](how-to/ci-gate.md)). `compare` now prints the interval next to every change. In the API, `Baseline_Diff` has the interval as `shift_pct`, `shift_low_pct`, and `shift_high_pct`, and `is_regression`, `is_improvement`, and `is_significant` follow the new rule.

### A baseline that can't be compared exits with status 3

A baseline that can't be read, holds none of a suite's benchmarks, was built with another optimization mode, OS, architecture, `-microarch`, or bounds-check setting, or counted allocations the other way used to fail a gate with exit status 1, like a regression. It now exits with 3 (#74), so a job can save the baseline again instead of failing. A script that treats every status other than 0 as a failure keeps working. One that checks for exactly 1 has to handle 3 too.

In the API, these problems moved from `Suite.failed_io`, which now only counts files that couldn't be written, to the new `Suite.failed_baseline`. A program with its own `main` should exit with `obench.suite_exit_code(&s)` rather than 1, to give the same statuses as the CLI. `obench compare` now also fails a gate, with 3, when the two reports have no benchmark in common, which it used to pass.

### New and not breaking

Format 6 of the JSON report (#69) adds fields that older readers ignore. `--filter` also matches regular expressions now, and every name the old substring filter selected is still selected. `--count`, `obench ab`, `--instructions`, `--counters`, `--test`, `--html`, and the rest are new options.

## 0.2 to 0.3

### Allocations are counted outside the timed samples

Up to 0.2, obench counted allocations in every timed sample, so a benchmark that allocates also paid for the counting. 0.3 counts them in one more batch after the samples, which runs untimed (#20). Benchmarks that allocate look faster in 0.3 than in 0.2 although nothing changed: in `examples/allocators` on an M2, counting in every sample made `heap` 14% slower and `temp_allocator` 19% slower.

Reports from 0.2 are format version 3 and counted the old way. A regression gate in 0.3 against such a baseline fails with a warning when it has a benchmark that allocates, since their times can't be compared. Save the baseline again with 0.3, or run with `--timed-allocs` until you do.

A `Config` literal that leaves out `untimed_alloc_check = true` still counts in every timed sample, since the field's zero value is false. Add the field, or start from `default_config()`, which sets it.
