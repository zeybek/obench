# Stability

obench is before 1.0. This page says what counts as its public surface and how that surface changes.

## The public surface

These are what you can build on, and what a release has to call out when it changes them:

- the stable part of the `obench` package, which the next section lists
- the CLI's subcommands, flags and exit statuses (0 success, 1 a failed benchmark, regression or build, or a baseline file that can't be read, 2 a usage error, 3 a baseline that can't be compared with the run)
- the `OBENCH_*` environment variables and the `#config(OBENCH_*)` defaults
- the benchmark conventions: `bench_<name>` and `bench_<group>__<name>` procedures, and the `@group`, `@params`, `@threads` and `@zero_alloc` annotations
- the JSON report: its fields and `format_version`, and the CSV report's columns

The terminal table, the Markdown report, the warnings and the runner the CLI generates are for people, and they can change in any release.

## The stable part of the package

The package exports more than it promises. The CLI and the tests are packages of their own, and Odin can't export a name to some packages only, so everything they call is exported as well. The promise covers:

- writing a benchmark: `step`, `pause`, `resume`, `scoped_pause`, `iter_batched`, `iter_with_large_drop`, `run_parallel`, `parallel_next`, `param`, `threads`, `set_bytes`, `set_items`, `report_metric`, `expect_zero_allocs`, `black_box`, `keep_alive` and `clobber_memory`, with the types `Bencher`, `Parallel_Bencher`, `Bench_Proc`, `Batch_Mode` and `Metric_Better`
- building and running a suite: `suite_create`, `suite_destroy`, `suite_run`, `suite_execute`, `suite_exit_code`, `suite_failure_count`, `suite_failure_messages`, `run_test`, `group_add`, `group_params`, `group_threads`, `group_bench`, `bench`, `default_config` and `apply_args`, with the types `Suite`, `Group`, `Entry`, `Config` and `Bench_Error`
- reading what a suite measured: the types `Result`, `Stats`, `Baseline_Diff`, `Suite_Summary`, `Complexity_Estimate`, `Complexity_Class`, `Custom_Metric`, `Counter_Values`, `Clock_Calibration` and `Machine_State`
- the constants `VERSION`, `EXIT_SUCCESS`, `EXIT_FAILURE`, `EXIT_USAGE`, `EXIT_BASELINE`, `MAX_CUSTOM_METRICS` and `MAX_METRIC_UNIT_LEN`

For these types the promise covers the fields whose names don't start with `_`. A release can add a field at any time.

Everything else the package exports is there for the CLI, the tests and tools that work on reports: the statistics behind the numbers (`compute_stats`, `compare_baseline`, `hodges_lehmann_shift` and the like), reading, writing, comparing and combining reports with their `Export_*` and `Comparison_*` types, the counting allocator, the clock, the hardware counters and the formatting helpers. These can change in any release, without the deprecation step below. The release notes still list such a change, and the JSON report they read and write keeps its own rule.

## How it changes before 1.0

A release with a breaking change bumps the minor version, so 0.3 goes to 0.4, the way Cargo treats `0.y` versions. Its commit title has a `!` (`feat!:` or `fix!:`), and the release notes list it under BREAKING CHANGES. A release with new features also bumps the minor version, and a release with only fixes bumps the patch version.

Before something in the stable part of the package is removed or renamed, it stays for one minor release marked `@(deprecated)` with a note on what to use instead, so code that uses it keeps building with a warning.

## The JSON report

`format_version` goes up whenever the layout changes. A field can be added to a format version only when old readers can ignore it, and readers should ignore fields they don't know. Odin's JSON reader already does. Removing a field, renaming it or changing what it means bumps `format_version` and counts as a breaking change. obench reads reports of every older format version: missing fields stay zero, and a baseline it can't compare fairly fails the regression gate with a warning and exit status 3.

## After 1.0

Breaking changes go into major versions only, as in [SemVer](https://semver.org/).
