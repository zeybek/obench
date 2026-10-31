/*
Allocation-aware micro-benchmarking for Odin.

`obench` measures wall-clock time per operation, heap and temp allocations per operation,
and (on x86) TSC cycles. Allocations are counted by swapping `context.allocator` and
`context.temp_allocator` inside the measured loop, so no global allocator hook is needed and
setup code outside the loop is never counted. It depends on `base:` and `core:` only.

Odin's `core:time.benchmark` times a single run of a procedure. obench adds warmup,
calibrated batches, per-sample statistics, allocation counts, `@zero_alloc` checks, and a
significance test for comparisons. The design borrows from Rust's divan and criterion, Go's
`testing.B` and benchstat, and google/benchmark.

Features:

- Automatic warmup and sample batch-size calibration
- Optimization barriers (`black_box`, `keep_alive`, `clobber_memory`)
- Allocation tracking (`allocs/op`, `bytes/op`, temp allocations) and `@zero_alloc` assertions
- Batched per-iteration setup and teardown (`iter_batched`) for destructive/in-place algorithms
- Multi-threaded contention benchmarking (`run_parallel` and thread-scaling groups)
- Big-O complexity inference for parameterized groups
- Custom domain metrics (`report_metric`)
- Statistics: percentiles, MAD, CI95, Tukey outliers, the Mann-Whitney U test, suite geomean
- `core:prof/spall` traces, JSON baselines, CSV, and Markdown reports

Install

This folder is the library. Copy it into your project, for example as `libs/obench`, and
import it with `import obench "libs/obench"`. Each release on
https://github.com/zeybek/obench/releases has it as `obench-<tag>-library.tar.gz` and
`.zip`, together with the license.

To keep the whole repository in your history and update it later, add it with git subtree
and import the folder inside it, `libs/obench/obench`. The CLI skips the examples and tests
of a copy like this.

	git subtree add --prefix=libs/obench https://github.com/zeybek/obench main --squash

To share one copy between projects, point a collection at the folder that contains it,
import `libs:obench`, and pass the same flag to the CLI with `--collection`.

	odin run my_bench -collection:libs=path/to/libs

Writing benchmarks

Put benchmarks in a package (usually a `*_bench.odin` file) as procedures named
`bench_<name>` that take a `^Bencher`. No `main` is needed, the CLI finds them with
`core:odin/parser`. Only the body of the `step` loop is timed and counted. Leaving the loop
early with `break` or `return` is reported as an error, because the sample would be
incomplete.

`black_box` stops the compiler from constant-folding an input or deleting an unused result.
`keep_alive` makes it assume the memory behind a pointer is read, so stores into it can't
be removed.

Comment annotations above a benchmark:

	bench_<group>__<name>   Benchmarks in the same group are compared side by side.
	                        Without __, the group is the file name minus _bench.
	// @group(name)         Sets the group explicitly.
	// @params(8, 64, 512)  Runs the group once per value (read it with param(b)). With 3 or
	                        more distinct values, obench fits a Big-O curve.
	// @threads(1, 2, 4)    Runs the group once per thread count (read it with threads(b),
	                        use run_parallel).
	// @zero_alloc          Fails the run if the measured loop allocates on the heap, and
	                        prints the file, line, and procedure of the first allocation.

Annotations go on comment lines of their own, and one line may hold several, as in
`// @zero_alloc @params(8, 64)`. Lines that don't start with `@` are prose, so a sentence that
mentions `@zero_alloc` changes nothing. A value the CLI can't read, such as `@params(1<<10)`
or `@threads(0)`, stops the package with the file and line, and an unknown name such as
`@param` is a warning.

`@params` and `@threads` belong to the group: the first benchmark in a group that declares
them sets them for the whole group, and the CLI warns if another benchmark in that group
declares different values.

Destructive benchmarks

When the routine mutates its input (sorting in place, popping from a queue), use
`iter_batched`. `setup` builds a batch of inputs with the clock and the allocation counters
paused, then `routine` runs over the whole batch in one timed window. `Batch_Mode` controls
how many inputs exist at once: `.Small_Input` (up to 4096), `.Large_Input` (128), or
`.Per_Iteration` (1).

	// @zero_alloc
	// @params(32, 128, 512)
	bench_in_place_sort__slice_sort :: proc(b: ^obench.Bencher) {
		obench.set_items(b, u64(obench.param(b)))
		obench.iter_batched(b, make_reverse_slice, std_quicksort, free_int_slice)
	}

Multi-threaded benchmarks

`run_parallel` splits the iteration budget across threads. Threads are created and released
outside the timed window, and they start from a spin-wait on a shared flag, so wake-up
latency isn't measured.

	// @zero_alloc
	// @threads(1, 2, 4)
	bench_contention__atomic_add :: proc(b: ^obench.Bencher) {
		obench.set_items(b, 1)
		obench.run_parallel(b, proc(pb: ^obench.Parallel_Bencher) {
			for obench.parallel_next(pb) {
				_ = intrinsics.atomic_add_explicit(&g_atomic_counter, 1, .Relaxed)
			}
		})
	}

The time per operation is wall time divided by the total iteration count across all
threads, so perfect scaling halves it each time the thread count doubles. Heap allocations
from workers go through the benchmark's counting allocator, which means the allocator behind
`context.allocator` has to be thread-safe (the default heap allocator is).

Running benchmarks

The CLI searches the directory and all subdirectories, skipping hidden ones and copies of
obench itself. A package is a benchmark package if it has `bench_*` procedures with the
`proc(b: ^Bencher)` signature, or if it has its own `main` and a `*_bench.odin` file. Other
programs are never run. For packages without a `main`, the CLI writes a small runner package
into a temporary directory, imports your package from there, and deletes it afterwards.
Nothing is written into your source tree. The compiler comes from `$ODIN` when it is set,
otherwise from `PATH`. Exit status is 0 on success, 1 when a benchmark, a gate, or a build
failed, and 2 for usage errors such as an unknown option. `obench help` lists the options.

A program can also run benchmarks from its own `main`. `suite_create` reads the `OBENCH_*`
environment variables and the command-line flags, so a program like this accepts
`--filter`, `--json`, and the rest. `suite_run` returns `false` when a benchmark misused the
API, a `@zero_alloc` check or a regression gate failed, or a report file couldn't be read or
written. examples/lookup in the repository is a full program.

	main :: proc() {
		s := obench.suite_create("lookup")
		defer obench.suite_destroy(&s)

		g := obench.group_add(&s, "lookup_by_key")
		obench.group_params(g, []int{8, 64, 512, 4096})
		obench.group_bench(g, "linear_scan", bench_linear_scan, zero_alloc = true)
		obench.group_bench(g, "binary_search", bench_binary_search, zero_alloc = true)

		if !obench.suite_run(&s) {
			os.exit(1)
		}
	}

Inside `odin test`, `run_test` runs a suite from a `@(test)` procedure, logs the report, and
fails the test on any of the problems `suite_run` reports. The benchmarks in Odin's own
repository time a fixed number of calls with `time.Stopwatch`. examples/core_style measures
`core:strings.prefix_length`, the same thing as Odin's `tests/benchmark/strings`. On an
Apple M2, for 1024 bytes of ASCII, Odin's benchmark timed 2500 calls at 44.5 µs, or 17.8 ns
per call. The obench example reported 19.25 ns fastest, 19.62 ns median, and 34.54 ns p99
for the same call, with a Big-O fit across six sizes and a check that the call doesn't
allocate.

	odin test examples/core_style -o:speed

Reading the report

Each sample is one calibrated batch (at least 1 ms by default), and the columns are per
operation. `x faster` and `x slower` compare each benchmark with the first one in its group
for the same parameter, and only appear when the Mann-Whitney U test finds the difference
significant and it is above 3%. Smaller or noisy differences show as `~1.04x (noise)`. The
sparkline is a histogram of the samples between the fastest and p99.

`allocs / bytes` counts allocator calls that obtain memory, which includes resizes: building
a 64-item dynamic array from capacity 16 shows `3.0 / 512 B` (one allocation, two resizes).
Temp-only allocations show as `0 (tmp 3.0/512 B)`.

On x86 there is also a `cycles` column with time-stamp counter ticks, which run at the CPU's
nominal frequency. On other architectures `read_cycle_counter` reads a fixed-frequency timer
(24 MHz on Apple Silicon), so the column is hidden there.

Comparing runs

Save a baseline on one branch and compare another branch against it, or compare two saved
reports without running anything:

	obench examples --save-baseline main.json
	obench examples --baseline main.json --fail-on-regression
	obench compare main.json branch.json --fail-on-regression

A change counts as a regression when the Mann-Whitney U test on the two runs' samples finds
a difference at the 5% level and the median moved by more than `--threshold` percent (2% by
default). The test works on ranks, so a few very slow samples in either run can't hide a
shift of the rest. Reports keep every sample for this (`samples_ns`, since format version 3).
Against an older report without samples, Welch's t-test on the means is used instead.
`--fail-on-regression` turns regressions into exit status 1, which makes it usable as a CI
gate. A baseline file that can't be read also fails the run, so a typo in the path doesn't
pass silently.

When the CLI runs several packages, `--json`, `--save-baseline`, `--csv`, and `--md` write one
merged file, with the suite name on every entry. `--spall` writes one trace per package
(`trace.spall` becomes `trace.sorting_bench.spall` and so on). Each package is its own suite,
named after the package. When two directories hold packages with the same name, their suites
also carry the directory, as in `bench (net/http)`. A program with its own `main` names its
suites itself, and if two such programs use the same suite name the CLI doesn't write the
merged JSON report, because a later comparison could match the wrong benchmarks.

Configuration

Programs that call `default_config` (which `suite_create` does when no config is passed)
pick up these environment variables. Command-line flags of the same name override them.

	OBENCH_FILTER                    Same as --filter
	OBENCH_SAMPLES, OBENCH_WARMUP_MS Sample count and warmup
	OBENCH_THRESHOLD                 Same as --threshold
	OBENCH_ZERO_ALLOC                1 or true to enable
	OBENCH_FAIL_ON_REGRESSION        1 or true to enable
	OBENCH_BASELINE                  Baseline to compare against
	OBENCH_SAVE_BASELINE             Where to save one
	OBENCH_JSON, OBENCH_MD           Report paths
	OBENCH_CSV                       Report path
	OBENCH_SPALL                     Trace path
	OBENCH_NO_COLOR, NO_COLOR        Disable colors

Compile-time defaults can be changed with `-define`:

	// Default number of samples collected per benchmark.
	DEFAULT_SAMPLES       : int    : #config(OBENCH_SAMPLES,       50)
	// Default warmup duration in milliseconds before sample calibration.
	DEFAULT_WARMUP_MS     : int    : #config(OBENCH_WARMUP_MS,     40)
	// Minimum target duration in microseconds for a single calibrated sample batch.
	DEFAULT_MIN_SAMPLE_US : int    : #config(OBENCH_MIN_SAMPLE_US, 1000)
	// Wall-clock budget in milliseconds for the sampling phase of one benchmark.
	DEFAULT_MAX_BENCH_MS  : int    : #config(OBENCH_MAX_BENCH_MS,  1200)
	// Enforce zero heap allocations globally across all benchmarks.
	DEFAULT_ZERO_ALLOC    : bool   : #config(OBENCH_ZERO_ALLOC,    false)
	// Enable ANSI color output in terminal reports.
	DEFAULT_COLOR         : bool   : #config(OBENCH_COLOR,         true)
	// Render 8-bin Unicode distribution sparklines in terminal reports.
	DEFAULT_HISTOGRAM     : bool   : #config(OBENCH_HISTOGRAM,     true)
	// Default Spall trace output path (empty disables tracing unless set in Config).
	DEFAULT_SPALL_PATH    : string : #config(OBENCH_SPALL_PATH,    "")

Limits

- Significance is computed from samples taken in one process. Two copies of the same code
  can still differ by a few percent there, because each copy sits at a different address.
  In testing, three identical benchmarks once came out 5% apart. Re-run before trusting a
  small difference.
- Shared CI runners are noisy, and a change only counts when it stands out from that noise.
  For a regression gate, raise the sample count with `-n` or use a dedicated machine.
- The CLI calls your benchmarks from a separate package, so they can't be `@(private)`, and a
  package named `main` without a `main` procedure can't be imported. The CLI reports both
  cases with the file and line.
- If the CLI is interrupted, its temporary runner directory stays in the system temp
  directory.
- The Big-O fit tries `T(N) = a + c * f(N)` for each class, so a fixed cost per call doesn't
  bend the curve, and only reports a growing class when it fits significantly better than a
  constant (an F-test at the 5% level). With 3 sizes that test is strict, so a noisy curve
  over few sizes can come out as O(1). Use 4 or more sizes when the class matters.
- Spall traces begin and end spans with `core:prof/spall`'s `_buffer_begin` and
  `_buffer_end`, as its package documentation shows, and name the process and thread with
  `_buffer_name_process` and `_buffer_name_thread`, which it doesn't document.

Example:

	package my_bench

	import "core:os"
	import "core:slice"
	import obench "libs/obench"

	bench_sum :: proc(b: ^obench.Bencher) {
		data := make([]int, 1024)
		defer delete(data)
		obench.expect_zero_allocs(b)
		for obench.step(b) {
			total := 0
			for v in data {
				total += v
			}
			_ = obench.black_box(total)
		}
	}

	bench_sort :: proc(b: ^obench.Bencher) {
		obench.iter_batched(
			b,
			setup    = proc(b: ^obench.Bencher) -> []int { return make([]int, 1024) },
			routine  = proc(data: ^[]int) { slice.sort(data^) },
			teardown = proc(data: ^[]int) { delete(data^) },
		)
	}

	main :: proc() {
		s := obench.suite_create("my_bench")
		defer obench.suite_destroy(&s)
		obench.bench(&s, "sum", bench_sum)
		obench.bench(&s, "sort", bench_sort)
		if !obench.suite_run(&s) {
			os.exit(1)
		}
	}
*/
package obench

// Version of the obench library and CLI.
VERSION :: "0.0.0" // x-release-please-version

// Default number of samples collected per benchmark.
DEFAULT_SAMPLES: int : #config(OBENCH_SAMPLES, 50)
// Default warmup duration in milliseconds before sample calibration.
DEFAULT_WARMUP_MS: int : #config(OBENCH_WARMUP_MS, 40)
// Minimum target duration in microseconds for a single calibrated sample batch.
DEFAULT_MIN_SAMPLE_US: int : #config(OBENCH_MIN_SAMPLE_US, 1000)
// Wall-clock budget in milliseconds for the sampling phase of one benchmark.
DEFAULT_MAX_BENCH_MS: int : #config(OBENCH_MAX_BENCH_MS, 1200)
// Enforce zero heap allocations globally across all benchmarks.
DEFAULT_ZERO_ALLOC: bool : #config(OBENCH_ZERO_ALLOC, false)
// Enable ANSI color output in terminal reports.
DEFAULT_COLOR: bool : #config(OBENCH_COLOR, true)
// Render 8-bin Unicode distribution sparklines in terminal reports.
DEFAULT_HISTOGRAM: bool : #config(OBENCH_HISTOGRAM, true)
// Default Spall trace output path.
DEFAULT_SPALL_PATH: string : #config(OBENCH_SPALL_PATH, "")
