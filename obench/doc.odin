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
- Statistics: percentiles, MAD, CI95, Tukey outliers, the Mann-Whitney U test, Hodges-Lehmann
  shift intervals, suite geomean
- `core:prof/spall` traces, JSON baselines, CSV, Markdown, and self-contained HTML reports

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
incomplete. A benchmark measures once: calling `iter_batched`, `iter_with_large_drop`, or
`run_parallel` after another measurement is reported as an error too.

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

`run_parallel` splits the iteration budget across threads: the group's `@threads` count, or
4 outside a thread-scaling group, unless `num_threads` is passed. Threads are created and
released outside the timed window, and the clock starts once every thread spins on a shared
start flag, so wake-up latency isn't measured.

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
threads, so perfect scaling halves it each time the thread count doubles. Workers use the
benchmark's `context.allocator` (the counting allocator while allocations are counted),
which means the allocator behind it has to be thread-safe (the default heap allocator is).

Running benchmarks

The CLI searches the directory and its subdirectories, skipping hidden ones, symbolic links,
and copies of obench itself. Like `odin build`, it leaves out files built only for another
platform (`_windows.odin`, `_linux_amd64.odin`, `#+build linux`), `#+ignore` files, and
`#+test` files, which only `odin test` builds. A
package is a benchmark package if it has `bench_*` procedures with the `proc(b: ^Bencher)`
signature, or if it has its own `main` and a `*_bench.odin` file. Other programs are never
run. For packages without a `main`, the CLI writes a small runner package into a temporary
directory, imports your package from there, and deletes it afterwards. Nothing is written
into your source tree. The compiler comes from `$ODIN` when it is set, otherwise from `PATH`.

Exit status is 0 on success, 1 when a benchmark, a gate, or a build failed, or a directory
with `*_bench.odin` files couldn't be parsed (the other packages still run), and 2 for usage
errors such as an unknown option, or a short flag given together with its long form
(`-n 5 --samples 100`). An annotation comment separated from its procedure by a blank line
is not read, so the CLI warns about it. `obench help` lists the options.

A program can also run benchmarks from its own `main`. `suite_create` reads the `OBENCH_*`
environment variables and the command-line flags, so a program like this accepts
`--filter`, `--json`, and the rest. `suite_run` returns `false` when a benchmark misused the
API, a `@zero_alloc` check or a regression gate failed, or a report file couldn't be read or
written. For programmatic callers that render their own output, `suite_execute` runs the suite
and writes any configured report files without printing to stdout. examples/lookup in the repository is a full program.

	main :: proc() {
		s := obench.suite_create("lookup")
		defer obench.suite_destroy(&s)

		g := obench.group_add(&s, "lookup_by_key")
		obench.group_params(g, []int{8, 64, 512, 4096})
		obench.group_bench(g, "linear_scan", bench_linear_scan, zero_alloc = true)
		obench.group_bench(g, "binary_search", bench_binary_search, zero_alloc = true)

		if !obench.suite_run(&s) {
			os.exit(obench.suite_exit_code(&s))
		}
	}

Inside `odin test`, `run_test` runs a suite from a `@(test)` procedure, logs the report, and
fails the test on any of the problems `suite_run` reports, with one failure per problem that
names the benchmark and the reason (`suite_failure_messages`). The benchmarks in Odin's own
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
for the same parameter, and only appear when the 95% confidence interval of the difference
lies beyond 3%. Smaller or noisy differences show as `~1.04x (noise)`. The
sparkline is a histogram of the samples between the fastest and p99. `[near timer
resolution]` marks a benchmark whose timed windows are less than 100 clock ticks long (an
expensive `iter_batched` setup can cut calibration short, and every `pause`/`resume` pair
starts a new window), so its times are quantized by 1% or more.

Every timed window also costs one clock overhead, which obench subtracts from the sample.
`[clamped: 4/50 samples]` means 4 samples came out below that overhead and were counted as 0,
so the times shown are too low, and `[overhead-dominated]` means the overhead was more than
10% of the raw time. Both usually come from calling `pause`/`resume` around work that is
smaller than the clock itself: time a bigger piece of work, or move the setup out of the loop.

After the benchmarks, obench times an empty `for obench.step(b) {}` loop and shows it in the
header (`empty loop 700.5 ps` on an M2). `[near empty loop]` marks a single-threaded benchmark
whose median is within 1.2 times of it: the compiler most likely removed the work, so pass
its input and result through `black_box`. Samples taken one after another aren't
independent, since one slow stretch of the machine covers several of them, so `ci95_ns`
counts only the samples they are worth (`effective_samples`, from the lag-1
`autocorrelation`). `[drifts +8%]` means the times moved steadily over the run, by that much
from the first sample to the last (see `sample_trend`), and `[2 modes]` that the samples fell
into separate groups (see `count_modes`); both usually mean the machine changed speed while
it ran. The JSON report has all four for every benchmark, and the empty loop as
`clock.empty_loop_ns`.

The header also warns about a machine that makes timings less steady: a CPU governor other
than `performance`, battery power, or a load average of half the cores or more, on Linux, and
the load on macOS. It notes turbo clocks and a virtual machine, and the JSON report records
all of it in `machine`. A baseline measured on another CPU model, or under another
`--machine` label, gets a warning too. `--pin <cpu>` runs the benchmarks on one logical CPU
on Linux and Windows, so the scheduler doesn't move them between cores; threads that
`run_parallel` starts share that CPU on Linux.

`allocs / bytes` counts allocator calls that obtain memory, which includes resizes: building
a 64-item dynamic array from capacity 16 shows `3.0 / 512 B` (one allocation, two resizes).
Temp-only allocations show as `0 (tmp 3.0/512 B)`. The counts come from one more batch
that runs untimed after the samples, so counting adds nothing to the measured time. A
`@zero_alloc` benchmark still has its heap checked in every timed sample, which costs
nothing until it allocates. `--timed-allocs` (or `OBENCH_UNTIMED_ALLOCS=0`) counts in every
timed sample instead, and then benchmarks that allocate also pay for the counting: in
`examples/allocators` on an M2, `heap` took 14% longer and `temp_allocator` 19% longer.

On Linux, `--counters` reads the CPU's hardware counters around every sample with
`perf_event_open` and adds per-operation columns for instructions, instructions per cycle,
and branch and cache misses (`Stats.counters`, and `instructions`, `cycles`,
`branch_misses`, and `cache_misses` in the JSON). Instructions barely move between runs, and
the misses often explain why something got slower. The counters cover the whole batch,
including the untimed work between `pause` and `resume`, and only the thread that runs the
benchmark, so a parallel benchmark gets none. Where the kernel doesn't allow them
(`perf_event_paranoid` above 2, a container's seccomp filter, or a VM without a PMU) the
header says why and the run goes on without them. `counter_group_open` is the same thing for
your own code.

On Linux with Valgrind, `obench --instructions` counts the instructions per operation
exactly, a number that can gate on a shared CI runner where time can't. It builds each
package once and runs every selected benchmark alone under Cachegrind twice, with N and 2N
iterations (`--batch-size`, 100 by default), and reports (I(2N) - I(N)) / N, so the process
start and the setup outside the loop cancel out. Each run does nothing but those iterations
(`Config.count_iterations`): no clock calibration, warmup, statistics, or output, so the
count is the same every time. Like the hardware counters, it includes the work between
`pause` and `resume`, and a benchmark that draws random input averages over the inputs that
N iterations draw, so another N can give another count. `--save-baseline` and `--json` write
the counts, and `--baseline` with `--fail-on-regression` fails when a benchmark needs more
than `--threshold` percent more instructions, with exit status 3 for a baseline that can't
be compared. Parallel benchmarks and packages with their own `main` are skipped.

On x86 there is also a `cycles` column with time-stamp counter ticks, which run at the CPU's
nominal frequency. On other architectures `read_cycle_counter` reads a fixed-frequency timer
(24 MHz on Apple Silicon), so the column is hidden there.

Comparing runs

Save a baseline on one branch and compare another branch against it, or compare two saved
reports without running anything:

	obench examples --save-baseline main.json
	obench examples --baseline main.json --fail-on-regression
	obench compare main.json branch.json --fail-on-regression

A change counts as a regression only when its whole 95% confidence interval lies above
`--threshold` percent (2% by default). The change is the Hodges-Lehmann estimate, the median
of the ratios between every sample of one run and every sample of the other, with the
distribution-free interval of the Mann-Whitney U test. The interval is exact up to 20
samples a side, and above that it widens when consecutive samples move together (see
`hodges_lehmann_shift`). It works on ranks, so a few very slow samples in either run can't
hide a shift of the rest. `compare` prints the interval and the Mann-Whitney p-value, and
under the summary the number of flags to expect from the noise between samples. That number
doesn't cover a machine that ran at another speed between the two runs, which shifts every
sample of one of them. Reports keep every sample for this (`samples_ns`, since format
version 3), along with each sample's overhead-adjusted integer batch duration
(`samples_batch_ns`, since format version 5) for downstream exact integer analysis. Against
an older report without samples, Welch's t-test on the means is used instead.

Since format version 6, a report also records where and how it was made, so history tools can
place it: `created_at` (UTC), the `git` commit, branch and whether the tree was dirty, the
GitHub Actions run in `ci`, the CPU model, core count and an optional `--machine` label in
`machine`, the `-microarch`, bounds checks and compiler commit in `build`, the run's
settings in `config`, and the clock calibration in `clock`. Every benchmark adds
`peak_heap_bytes`, whether it was checked as `@zero_alloc` and failed, and how much of its
time was clock overhead. The CLI takes the commit from `git` in the directory it runs, and a
program with its own `main` from `OBENCH_GIT_COMMIT` or GitHub Actions' `GITHUB_SHA`. A custom
metric can say which way it improves with the `better` argument of `report_metric`.

Every report names its JSON Schema in `$schema` (`REPORT_SCHEMA_URL`). The `schema/` folder of
the repository holds one schema per format version, the docs site publishes them under
`/obench/schema/`, and CI checks the reports of all examples against the current one. A field
is added within a format version only when old readers can ignore it, readers should ignore
fields they don't know, and removing or changing a field bumps `format_version` (see
STABILITY.md).

`--fail-on-regression` turns regressions into exit status 1, which makes it usable as a CI
gate. A baseline that can't be compared with the run gives exit status 3 instead
(`EXIT_BASELINE`), so a CI job can tell "this got slower" from "save the baseline again".
That is a baseline file that can't be read, so a typo in the path doesn't pass silently, and
under `--fail-on-regression` or `--fail-on-alloc-regression` one that holds none of a
suite's benchmarks (a renamed suite, or the wrong file). Under `--fail-on-regression` it is
also a baseline built with another optimization mode, OS, architecture, `-microarch`, or
bounds-check setting, because its timings can't be compared: one saved from an `-o:none`
build would make every benchmark look faster and hide a real regression. The same goes for a
baseline that counted allocations the other way when it has a benchmark that allocates;
reports older than format version 4 counted them in every timed sample, so against one of
them those benchmarks look faster. Save the baseline again, or run with `--timed-allocs`
until then. Time regressions against such a baseline don't count, but a benchmark that
failed or allocates more still gives 1. A program with its own `main` gets the same status
from `suite_exit_code`. `obench compare` checks the two reports the same way
(`comparison_exit_code`). Its `--fail-on-regression` also fails when a benchmark that worked
in the baseline reports an error in the candidate; benchmarks found on one side only are
listed but don't fail it, unless no benchmark is on both sides.
`--md` and `--json` write the comparison as well: Markdown with a one-line verdict first and
the table in a `<details>` block, for a job summary or a pull request comment, and JSON with
the summary and every benchmark's verdict, for a bot (`write_comparison_markdown`,
`write_comparison_json`).

Allocation counts are exact, so they make a gate that holds even on a noisy shared runner.
`--fail-on-alloc-regression` fails the run, or `obench compare`, when a benchmark allocates
more per operation than in the baseline: more heap or temp allocations, or more bytes. There
is no threshold and no test, and the table marks such a benchmark `[allocs grew]`. A baseline
that holds none of a suite's benchmarks fails this gate too.

Repeating runs

All the samples of a run come from one process, and two processes running the same code
differ by more than the samples inside one: the memory layout, the environment, and the
machine change between them. So two runs of unchanged code often look different.
`--count 5` runs every package in 5 processes, each started with a random amount of padding
in its environment and a random offset of its stack, and combines their reports
(`combine_runs`): the samples are pooled, and the median of every process is kept in
`process_medians_ns`. When both sides of a comparison come from at least two processes, the
regression test compares the process medians instead of the samples, so a gate only fails
on a change that holds across processes. It takes 5 times as long. `--count` writes
`--json`, `--save-baseline`, and `--html`, but not `--md`, `--csv`, or `--spall`. The first
process prints its table, the others their summary line, and then a table of every
benchmark's median with the range of its process medians.

A baseline saved on another day, or by another CI job, has drifted with its machine.
`obench ab ../main .` builds both trees and runs them on this machine alternately, 6 rounds
by default (`--rounds`), each round in a random order of the two sides, so drift falls on
both alike; then it compares them like `compare`, process medians against process medians.
Use at least 6 rounds: with 4 or fewer, the 95% interval stretches over every difference
between the two sides' processes, so it is too wide to flag much. `obench compare a1.json
a2.json -- b1.json b2.json` combines several reports on each side the same way (options go
before `--`).

Selecting benchmarks

`--filter` runs the benchmarks whose full name contains the pattern, either as plain text or
as a `core:text/regex` regular expression, so `-f 'odin_map\[(8|64)\]'` picks two parameters
and `-f 'odin_map[64]'` still picks the one name it contains. `--skip` leaves out the names it
matches the same way, and `--exact` runs the one benchmark with exactly that full name
(`obench list --json` prints every full name). A selection that matches nothing writes no
report files, so a typo can't replace a saved baseline with an empty one.

`--max-time` and `--min-sample-time` set the time budget of a benchmark and the shortest
sample at run time, like `--max-time 200ms --min-sample-time 500us`, and `--batch-size` fixes
the iterations per sample instead of calibrating them. `--test` runs every benchmark once
with one iteration, with the protocol, `@zero_alloc`, and allocation checks, but measures
nothing, so it can't read or save a baseline; it is a quick check for a CI job. `-q` prints
only the problems and the summary line.

When the CLI runs several packages, `--json`, `--save-baseline`, `--csv`, `--md`, and
`--html` write one merged file, with the suite name on every entry. `--spall` writes one
trace per package (`trace.spall` becomes `trace.sorting_bench.spall` and so on). Each package is its own suite,
named after the package, and compares only with the entries of its own suite in a baseline.
When two directories hold packages with the same name, their suites also carry the directory
relative to the path given to the CLI, as in `bench (net/http)`, so compare runs started
from the same directory. The merged JSON report takes its Odin version, optimization mode,
and platform from the packages' own reports. A program with its own `main` names its
suites itself, and if two such programs use the same suite name the CLI doesn't write the
merged JSON report, because a later comparison could match the wrong benchmarks.

Configuration

Programs that call `default_config` (which `suite_create` does when no config is passed)
pick up these environment variables. Command-line flags of the same name override them.

	OBENCH_FILTER, OBENCH_SKIP       Same as --filter and --skip
	OBENCH_EXACT                     Same as --exact
	OBENCH_SAMPLES, OBENCH_WARMUP_MS Sample count and warmup
	OBENCH_MAX_TIME                  Same as --max-time
	OBENCH_MIN_SAMPLE_TIME           Same as --min-sample-time
	OBENCH_BATCH_SIZE                Same as --batch-size
	OBENCH_TEST, OBENCH_QUIET        1 or true: same as --test and -q
	OBENCH_THRESHOLD                 Same as --threshold
	OBENCH_ZERO_ALLOC                1 or true to enable
	OBENCH_UNTIMED_ALLOCS            0 or false: same as --timed-allocs
	OBENCH_FAIL_ON_REGRESSION        1 or true to enable
	OBENCH_FAIL_ON_ALLOC_REGRESSION  1 or true to enable
	OBENCH_BASELINE                  Baseline to compare against
	OBENCH_SAVE_BASELINE             Where to save one
	OBENCH_JSON, OBENCH_MD           Report paths
	OBENCH_HTML                      Same as --html
	OBENCH_CSV                       Report path
	OBENCH_SPALL                     Trace path
	OBENCH_MACHINE                   Same as --machine
	OBENCH_PIN                       Same as --pin
	OBENCH_COUNTERS                  1 or true: same as --counters
	OBENCH_COUNT_ITERATIONS          Same as --count-iterations (see Config.count_iterations)
	OBENCH_GIT_COMMIT, _BRANCH, _DIRTY  The commit for the report (set by the CLI)
	OBENCH_NO_COLOR, NO_COLOR        Disable colors
	FORCE_COLOR                      Keep colors when the output isn't a terminal

Colors are also off when standard output isn't a terminal, such as a file, a pipe, or a CI
log, unless `FORCE_COLOR` is set to anything but `0`.

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
	// Count allocations in one untimed batch after the timed samples.
	DEFAULT_UNTIMED_ALLOCS: bool   : #config(OBENCH_UNTIMED_ALLOCS, true)
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
  over few sizes can come out as O(1). Use 4 or more sizes when the class matters. For O(1)
  the reported R² is 1 - NRMSE², how flat the times are, since a constant explains no
  variance.
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
			os.exit(obench.suite_exit_code(&s))
		}
	}
*/
package obench

// Version of the obench library and CLI.
VERSION :: "0.3.0" // x-release-please-version

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
// Count allocations in one untimed batch after the timed samples.
DEFAULT_UNTIMED_ALLOCS: bool : #config(OBENCH_UNTIMED_ALLOCS, true)
// Enable ANSI color output in terminal reports.
DEFAULT_COLOR: bool : #config(OBENCH_COLOR, true)
// Render 8-bin Unicode distribution sparklines in terminal reports.
DEFAULT_HISTOGRAM: bool : #config(OBENCH_HISTOGRAM, true)
// Default Spall trace output path.
DEFAULT_SPALL_PATH: string : #config(OBENCH_SPALL_PATH, "")
