package obench

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:text/regex"
import "core:time"

// A benchmark always keeps at least this many samples before the time budget can stop it.
MIN_SAMPLES :: 10

@(private = "file")
_Run_Info :: struct {
	entry:              Entry,
	group_name:         string,
	param:              int,
	has_param:          bool,
	threads:            int,
	has_threads:        bool,
	enforce_zero_alloc: bool,
	temp_arena:         ^runtime.Arena,
}

@(private = "file")
_Batch_Result :: struct {
	ns:                   i64,
	cycles:               u64,
	windows:              int,
	bytes_per_op:         u64,
	items_per_op:         u64,
	expect_zero:          bool,
	metric_values:        [MAX_CUSTOM_METRICS]f64,
	metric_units:         [MAX_CUSTOM_METRICS][MAX_METRIC_UNIT_LEN]u8,
	metric_unit_lens:     [MAX_CUSTOM_METRICS]int,
	metric_better:        [MAX_CUSTOM_METRICS]Metric_Better,
	custom_metrics_count: int,
	error:                Bench_Error,
}

// Runs the benchmark procedure once with `batch_size` iterations. The benchmark's
// `context.temp_allocator` is obench's private arena, never the caller's temp allocator.
@(private = "file")
_run_batch :: proc(
	info: ^_Run_Info,
	batch_size: int,
	heap_counter: ^Counting_Allocator,
	temp_counter: ^Counting_Allocator,
) -> (
	res: _Batch_Result,
) {
	b := Bencher {
		name              = info.entry.name,
		group_name        = info.group_name,
		param             = info.param,
		has_param         = info.has_param,
		threads           = info.threads > 0 ? info.threads : 1,
		has_threads       = info.has_threads,
		user_ptr          = info.entry.user_ptr,
		remaining_iters   = batch_size,
		batch_size        = batch_size,
		expect_zero_alloc = info.enforce_zero_alloc || info.entry.enforce_zero_alloc,
		_heap_counter     = heap_counter,
		_temp_counter     = temp_counter,
	}

	_set_counters_paused(&b, true)
	if heap_counter != nil {
		// Always remember where the first measured allocation happened: `expect_zero_allocs`
		// may be called after the loop, and the verdict is taken after the run.
		heap_counter.enforce_zero_allocs = true
	}

	bench_ctx := context
	if heap_counter != nil {
		bench_ctx.allocator = counting_allocator(heap_counter)
	}
	if temp_counter != nil {
		bench_ctx.temp_allocator = counting_allocator(temp_counter)
	} else {
		bench_ctx.temp_allocator = runtime.arena_allocator(info.temp_arena)
	}

	{
		context = bench_ctx
		info.entry.procedure(&b)
	}

	// Leave the counters paused no matter how the procedure returned.
	_set_counters_paused(&b, true)

	switch {
	case b._measured_twice:
		res.error = .Measured_Twice
	case !b._started_sample:
		res.error = .No_Measurement
	case !b._finished && b.remaining_iters > 0:
		res.error = .Loop_Exited_Early
	}

	res.ns = b._accum_ns
	res.cycles = b._accum_cycles
	res.windows = b._windows
	res.bytes_per_op = b.bytes_per_op
	res.items_per_op = b.items_per_op
	res.expect_zero = b.expect_zero_alloc
	res.custom_metrics_count = b.custom_metrics_count
	for i in 0 ..< b.custom_metrics_count {
		res.metric_values[i] = b.custom_metrics[i].value
		res.metric_unit_lens[i] = copy(res.metric_units[i][:], b.custom_metrics[i].unit)
		res.metric_better[i] = b.custom_metrics[i].better
	}
	return
}

/*
Runs one more batch of `batch_size` iterations, untimed, with a counter that records the size
of every block (see `_Size_Tracker`), and returns the most heap bytes live at once. The
sampling loop can't do this itself: the map and its lock would be timed with every allocation.
*/
@(private = "file")
_measure_peak_heap :: proc(info: ^_Run_Info, batch_size: int, reset_temp: bool) -> i64 {
	tracker := _Size_Tracker {
		sizes = make(map[rawptr]int),
	}
	defer delete(tracker.sizes)

	heap_counter: Counting_Allocator
	counting_allocator_init(&heap_counter, context.allocator)
	heap_counter._tracker = &tracker
	_ = _run_batch(info, batch_size, &heap_counter, nil)
	if reset_temp {
		runtime.arena_free_all(info.temp_arena)
	}
	return intrinsics.atomic_load_explicit(&heap_counter.peak_bytes, .Relaxed)
}

@(private = "file")
_fail_entry :: proc(s: ^Suite, result: ^Result, err: Bench_Error) -> Result {
	result.error = err
	s.failed_errors += 1
	return result^
}

@(private = "file")
_store_batch_custom_metrics :: proc(
	dst: ^[MAX_CUSTOM_METRICS]Custom_Metric,
	dst_count: ^int,
	br: ^_Batch_Result,
	allocator: runtime.Allocator,
) {
	if br.custom_metrics_count <= 0 {
		return
	}
	for j in 0 ..< dst_count^ {
		delete(dst[j].unit, allocator)
	}
	dst_count^ = br.custom_metrics_count
	for j in 0 ..< dst_count^ {
		unit := string(br.metric_units[j][:br.metric_unit_lens[j]])
		dst[j] = Custom_Metric {
			unit   = strings.clone(unit, allocator),
			value  = br.metric_values[j],
			better = br.metric_better[j],
		}
	}
}

@(private = "file")
_execute_entry :: proc(
	s: ^Suite,
	group_name: string,
	entry: Entry,
	param_val: int,
	has_param: bool,
	thread_val: int,
	has_threads: bool,
	baseline_map: map[string]Stats,
	spall_rec: ^Spall_Recorder,
	temp_arena: ^runtime.Arena,
	counters: ^Counter_Group = nil,
) -> Result {
	cfg := s.config
	full_name := format_full_name(
		group_name,
		entry.name,
		param_val,
		has_param,
		thread_val,
		has_threads,
		s.allocator,
	)

	spall_begin(spall_rec, full_name)
	defer spall_end(spall_rec)

	result := Result {
		group_name         = group_name,
		name               = entry.name,
		full_name          = full_name,
		param              = param_val,
		has_param          = has_param,
		threads            = thread_val > 0 ? thread_val : 1,
		has_threads        = has_threads,
		speedup_vs_fastest = 1.0,
		speedup_vs_first   = 1.0,
	}

	expect_zero := cfg.enforce_zero_allocs || entry.enforce_zero_alloc
	info := _Run_Info {
		entry              = entry,
		group_name         = group_name,
		param              = param_val,
		has_param          = has_param,
		threads            = thread_val,
		has_threads        = has_threads,
		enforce_zero_alloc = expect_zero,
		temp_arena         = temp_arena,
	}

	// 1. Warmup. At least one batch always runs, which also validates the procedure.
	{
		spall_begin(spall_rec, "warmup")
		defer spall_end(spall_rec)

		// `--test` runs the one batch that validates the procedure and nothing more.
		warmup_budget := i64(cfg.warmup_time) if !cfg.test_mode else 0
		warmup_elapsed: i64 = 0
		warmup_batch := 1
		wall_start := time.tick_now()
		for {
			br := _run_batch(&info, warmup_batch, nil, nil)
			if cfg.reset_temp_per_iter {
				runtime.arena_free_all(temp_arena)
			}
			if br.error != .None {
				return _fail_entry(s, &result, br.error)
			}
			// `expect_zero_allocs` inside the procedure is only seen once it has run.
			expect_zero = expect_zero || br.expect_zero
			warmup_elapsed += max(br.ns, 1)
			if warmup_elapsed >= warmup_budget {
				break
			}
			// Heavy untimed setup must not stretch the warmup indefinitely.
			if i64(time.tick_since(wall_start)) >= 5 * warmup_budget {
				break
			}
			if br.ns < warmup_budget / 8 && warmup_batch < 1_000_000 {
				warmup_batch *= 4
			}
		}
	}

	// 2. Auto-calibrate batch_size so each sample takes >= min_sample_time.
	batch_size := cfg.fixed_batch_size if !cfg.test_mode else 1
	if batch_size <= 0 {
		spall_begin(spall_rec, "calibrate")
		defer spall_end(spall_rec)

		target_ns := max(i64(cfg.min_sample_time), 50_000)
		// Untimed setup (`iter_batched`) can make a probe far longer than its timed part.
		probe_wall_budget := max(i64(cfg.max_bench_time), 20 * target_ns)
		probe_start := time.tick_now()
		probe_batch := 1
		for {
			batch_start := time.tick_now()
			br := _run_batch(&info, probe_batch, nil, nil)
			batch_wall := i64(time.tick_since(batch_start))
			if cfg.reset_temp_per_iter {
				runtime.arena_free_all(temp_arena)
			}
			if br.error != .None {
				return _fail_entry(s, &result, br.error)
			}
			ns := br.ns
			growth := ns <= 0 ? 10 : clamp(int(target_ns / max(ns, 1)), 2, 16)
			// Stop before a probe that would run past the budget.
			out_of_time :=
				i64(time.tick_since(probe_start)) + batch_wall * i64(growth) > probe_wall_budget
			// A probe that stalled (an interrupt, a page fault, a busy host) would end the
			// calibration with a batch far too small, so the probe that would end it runs once
			// more while the budget allows, and the faster run counts.
			if (ns >= target_ns || out_of_time) &&
			   i64(time.tick_since(probe_start)) + batch_wall <= probe_wall_budget {
				again_start := time.tick_now()
				again := _run_batch(&info, probe_batch, nil, nil)
				again_wall := i64(time.tick_since(again_start))
				if cfg.reset_temp_per_iter {
					runtime.arena_free_all(temp_arena)
				}
				if again.error != .None {
					return _fail_entry(s, &result, again.error)
				}
				ns = min(ns, again.ns)
				batch_wall = min(batch_wall, again_wall)
				growth = ns <= 0 ? 10 : clamp(int(target_ns / max(ns, 1)), 2, 16)
				out_of_time =
					i64(time.tick_since(probe_start)) + batch_wall * i64(growth) >
					probe_wall_budget
			}
			if ns >= target_ns || probe_batch >= 10_000_000 || out_of_time {
				if out_of_time && ns < target_ns {
					batch_size = probe_batch // Growing it would make every sample as slow.
				} else if ns > 0 {
					estimated := int((f64(target_ns) / f64(ns)) * f64(probe_batch))
					batch_size = clamp(estimated, 1, 10_000_000)
				} else {
					batch_size = probe_batch
				}
				break
			}
			probe_batch *= growth
		}
	}

	// 3. Sample collection with allocation tracking.
	sample_target := max(cfg.sample_count, 5) if !cfg.test_mode else 1
	// The time budget usually ends sampling long before a huge `sample_count`.
	initial_cap := min(sample_target, 1024)
	ns_samples := make([dynamic]f64, 0, initial_cap, s.allocator)
	defer delete(ns_samples)
	batch_samples := make([dynamic]u64, 0, initial_cap, s.allocator)
	defer delete(batch_samples)
	cyc_samples := make([dynamic]f64, 0, initial_cap, s.allocator)
	defer delete(cyc_samples)

	heap_counter: Counting_Allocator
	temp_counter: Counting_Allocator
	counting_allocator_init(&heap_counter, context.allocator)
	counting_allocator_init(&temp_counter, runtime.arena_allocator(temp_arena))
	// With `untimed_alloc_check`, a benchmark that expects zero allocations still has its
	// heap watched in every timed sample. That costs nothing until it allocates, and then
	// the benchmark fails anyway.
	zero_check: Counting_Allocator
	counting_allocator_init(&zero_check, context.allocator)
	sample_heap_counter: ^Counting_Allocator = &heap_counter
	sample_temp_counter: ^Counting_Allocator = &temp_counter
	if cfg.untimed_alloc_check {
		sample_heap_counter = &zero_check if expect_zero else nil
		sample_temp_counter = nil
	}

	total_iters: u64 = 0
	max_bench_ns := i64(cfg.max_bench_time)
	bytes_per_op: u64 = 0
	items_per_op: u64 = 0

	last_custom: [MAX_CUSTOM_METRICS]Custom_Metric
	last_custom_count := 0
	defer {
		for i in 0 ..< last_custom_count {
			delete(last_custom[i].unit, s.allocator)
		}
	}

	// Hardware counters count the calling thread only, so the threads of a parallel benchmark
	// would go unseen.
	counting := counters != nil && counters.open && !(has_threads && thread_val > 1)
	counter_samples: [4][dynamic]f64
	for &c in counter_samples {
		c = make([dynamic]f64, 0, 16, context.temp_allocator)
	}

	arg_buf: [48]u8
	batch_arg := fmt.bprintf(arg_buf[:], "batch=%d", batch_size)
	clamped_samples := 0
	overhead_share_sum, windows_sum: f64
	sampling_start := time.tick_now()
	for i := 0; i < sample_target; i += 1 {
		// Peak live bytes are tracked per sample.
		if !cfg.untimed_alloc_check {
			intrinsics.atomic_store_explicit(&heap_counter.current_bytes, 0, .Relaxed)
		}
		spall_begin(spall_rec, "sample", batch_arg)
		before, after: Counter_Values
		read_before, read_after: bool
		if counting {
			before, read_before = counter_group_read(counters)
		}
		br := _run_batch(&info, batch_size, sample_heap_counter, sample_temp_counter)
		if counting {
			after, read_after = counter_group_read(counters)
		}
		spall_end(spall_rec)
		if read_before && read_after {
			per_op := f64(max(batch_size, 1))
			append(&counter_samples[0], (after.instructions - before.instructions) / per_op)
			append(&counter_samples[1], (after.cycles - before.cycles) / per_op)
			append(&counter_samples[2], (after.branch_misses - before.branch_misses) / per_op)
			append(&counter_samples[3], (after.cache_misses - before.cache_misses) / per_op)
		}

		_store_batch_custom_metrics(&last_custom, &last_custom_count, &br, s.allocator)
		if cfg.reset_temp_per_iter {
			runtime.arena_free_all(temp_arena)
		}
		if br.error != .None {
			return _fail_entry(s, &result, br.error)
		}

		bytes_per_op = br.bytes_per_op
		items_per_op = br.items_per_op
		expect_zero = br.expect_zero

		// A sample below the clock overhead is clamped to 0: the work is too small to see.
		windows := f64(max(br.windows, 1))
		overhead_ns := s.clock.overhead_ns * windows
		if f64(br.ns) < overhead_ns {
			clamped_samples += 1
		}
		if br.ns > 0 {
			overhead_share_sum += min(overhead_ns / f64(br.ns), 1)
		} else {
			overhead_share_sum += 1
		}
		windows_sum += windows
		adj_ns := max(f64(br.ns) - overhead_ns, 0)
		adj_cyc := max(f64(br.cycles) - s.clock.overhead_cycles * windows, 0)

		adj_batch_ns := u64(math.round(adj_ns))

		append(&ns_samples, adj_ns / f64(batch_size))
		append(&batch_samples, adj_batch_ns)
		append(&cyc_samples, adj_cyc / f64(batch_size))
		total_iters += u64(batch_size)

		if i + 1 >= MIN_SAMPLES &&
		   max_bench_ns > 0 &&
		   i64(time.tick_since(sampling_start)) >= max_bench_ns {
			break
		}
	}

	alloc_iters := total_iters
	if cfg.untimed_alloc_check {
		intrinsics.atomic_store_explicit(&heap_counter.current_bytes, 0, .Relaxed)
		spall_begin(spall_rec, "alloc check", batch_arg)
		abr := _run_batch(&info, batch_size, &heap_counter, &temp_counter)
		spall_end(spall_rec)
		_store_batch_custom_metrics(&last_custom, &last_custom_count, &abr, s.allocator)
		if cfg.reset_temp_per_iter {
			runtime.arena_free_all(temp_arena)
		}
		if abr.error != .None {
			return _fail_entry(s, &result, abr.error)
		}
		expect_zero = expect_zero || abr.expect_zero
		alloc_iters = u64(batch_size)
	}

	st := compute_stats(
		ns_samples[:],
		cyc_samples[:],
		batch_size,
		total_iters,
		bytes_per_op,
		items_per_op,
		&heap_counter,
		&temp_counter,
		last_custom[:last_custom_count],
		s.allocator,
		alloc_iters,
	)
	st.samples_ns = slice.clone(ns_samples[:], s.allocator)
	st.samples_batch_ns = slice.clone(batch_samples[:], s.allocator)
	if len(counter_samples[0]) > 0 {
		median :: proc(values: []f64) -> f64 {
			slice.sort(values)
			return percentile_sorted(values, 0.5)
		}
		st.counters = Counter_Values {
			instructions  = median(counter_samples[0][:]),
			cycles        = median(counter_samples[1][:]),
			branch_misses = median(counter_samples[2][:]),
			cache_misses  = median(counter_samples[3][:]),
		}
		st.has_counters = true
	}
	if n := len(ns_samples); n > 0 {
		st.clamped_samples = clamped_samples
		st.windows_per_sample = windows_sum / f64(n)
		st.overhead_share = overhead_share_sum / f64(n)
	}
	last_custom_count = 0 // Ownership of the unit strings moves to the result.

	// A `free` that doesn't pass the block's size never lowered the live bytes, so the peak
	// above may be the sum of the sample's allocations. Measure it again without the clock.
	if intrinsics.atomic_load_explicit(&heap_counter.freed_without_size, .Relaxed) {
		spall_begin(spall_rec, "peak heap")
		st.peak_heap_bytes = _measure_peak_heap(&info, batch_size, cfg.reset_temp_per_iter)
		spall_end(spall_rec)
	}

	if base_st, ok := baseline_map[full_name]; ok {
		result.diff = compare_baseline(st, base_st, cfg.noise_threshold_pct)
		if result.diff.is_regression && cfg.fail_on_regression {
			s.failed_regressions += 1
		}
		if result.diff.allocs_grew && cfg.fail_on_alloc_regression {
			s.failed_alloc_regressions += 1
		}
	}

	result.stats = st
	// The timed samples ran first, so their violation is the first one.
	violation := &zero_check if zero_check.zero_alloc_violated else &heap_counter
	result.zero_alloc = expect_zero
	result.zero_alloc_failed = expect_zero && violation.zero_alloc_violated
	if result.zero_alloc_failed {
		s.failed_zero_alloc += 1
		result.violation_loc = violation.first_violation_loc
		result.violation_size = violation.first_violation_size
	}
	return result
}

@(private = "file")
_write_report_file :: proc(
	s: ^Suite,
	path: string,
	kind: string,
	save: proc(s: ^Suite, path: string) -> Report_Error,
) {
	if path == "" {
		return
	}
	if err := save(s, path); err != nil {
		fmt.eprintfln("obench: could not write %s report to '%s' (%v)", kind, path, err)
		s.failed_io += 1
	}
}

// Fills `speedup_vs_first`, `speedup_vs_fastest`, and `speedup_significant` for `results`
// relative to the first entry.
@(private = "file")
_compute_speedups :: proc(results: []Result) {
	if len(results) < 2 {
		return
	}
	SPEEDUP_THRESHOLD_PCT :: 3.0

	ref := &results[0]
	fastest_ns := max(f64)
	for &r in results {
		if r.error == .None && r.stats.p50_ns > 0 && r.stats.p50_ns < fastest_ns {
			fastest_ns = r.stats.p50_ns
		}
	}
	for &r in results {
		med := r.stats.p50_ns
		if r.error != .None || med <= 0 {
			continue
		}
		if fastest_ns < max(f64) {
			r.speedup_vs_fastest = med / fastest_ns
		}
		if ref.error == .None && ref.stats.p50_ns > 0 {
			r.speedup_vs_first = ref.stats.p50_ns / med
			diff := compare_baseline(r.stats, ref.stats, SPEEDUP_THRESHOLD_PCT)
			r.speedup_significant = diff.is_significant
		}
	}
}

/*
Runs all matching benchmarks in the suite, computes cohort speedups and Big-O complexity, and
writes the configured JSON/Markdown/CSV/baseline/Spall files without printing to stdout.

obench's own temporary allocations go to a private arena, so a run does not grow the
caller's `context.temp_allocator`.

Returns `true` when every benchmark ran correctly, every `@zero_alloc` assertion and
`fail_on_regression` gate passed, and every requested file was read or written.
*/
@(require_results)
suite_execute :: proc(s: ^Suite) -> bool {
	scratch := runtime.Arena {
		backing_allocator = s.allocator,
	}
	defer runtime.arena_destroy(&scratch)
	context.temp_allocator = runtime.arena_allocator(&scratch)

	if pad := _stack_offset(); pad > 0 {
		shift := intrinsics.alloca(pad, 16)
		_ = black_box(shift)
	}
	return _suite_execute(s)
}

/*
Runs all matching benchmarks in the suite, computes cohort speedups and Big-O complexity,
writes the configured JSON/Markdown/CSV/baseline/Spall files, and prints the terminal report.

obench's own temporary allocations go to a private arena, so a run does not grow the
caller's `context.temp_allocator`.

Returns `true` when every benchmark ran correctly, every `@zero_alloc` assertion and
`fail_on_regression` gate passed, and every requested file was read or written.
*/
@(require_results)
suite_run :: proc(s: ^Suite) -> bool {
	scratch := runtime.Arena {
		backing_allocator = s.allocator,
	}
	defer runtime.arena_destroy(&scratch)
	context.temp_allocator = runtime.arena_allocator(&scratch)

	if pad := _stack_offset(); pad > 0 {
		shift := intrinsics.alloca(pad, 16)
		_ = black_box(shift)
	}
	ok := _suite_execute(s)
	if s.config.count_iterations <= 0 {
		print_terminal_report(s)
	}
	return ok
}

/*
Number of problems found by the last `suite_run` or `run_test`: misused benchmarks, failed
`@zero_alloc` checks, time and allocation regressions that fail the run, files that couldn't
be read or written, and baselines that can't be compared with the run.
*/
@(require_results)
suite_failure_count :: proc "contextless" (s: ^Suite) -> int {
	return(
		s.failed_zero_alloc +
		s.failed_regressions +
		s.failed_alloc_regressions +
		s.failed_errors +
		s.failed_io +
		s.failed_baseline \
	)
}

// Exit status of a run or comparison that passed.
EXIT_SUCCESS :: 0
// Exit status when a benchmark failed or regressed, or a file couldn't be read or written.
EXIT_FAILURE :: 1
// Exit status of the CLI for a usage error: an unknown flag or a missing argument.
EXIT_USAGE :: 2
// Exit status when the baseline can't be compared with the run, so CI can save it again.
EXIT_BASELINE :: 3

/*
Exit status for a program that ran `s`, as the CLI's generated runner uses it:

- `EXIT_SUCCESS` (0) when `suite_run` passed
- `EXIT_FAILURE` (1) when a benchmark failed or regressed, or a file couldn't be read or
  written. That includes the baseline file, so a typo in its path isn't taken for a baseline
  to save again.
- `EXIT_BASELINE` (3) when the baseline was read but can't be compared with this run: it was
  built with another optimization mode, OS, or architecture, counted allocations the other
  way, holds none of the suite's benchmarks, or leaves a benchmark with too few samples on a
  side for a 95% interval (`Baseline_Diff.too_few_samples`)

Time regressions against a baseline that can't be compared don't count, since its times mean
nothing for this run, but a failed benchmark or a growth in allocations still gives 1. A CI
job can save the baseline again on 3 instead of failing.
*/
@(require_results)
suite_exit_code :: proc "contextless" (s: ^Suite) -> int {
	if s.failed_errors + s.failed_zero_alloc + s.failed_io + s.failed_alloc_regressions > 0 {
		return EXIT_FAILURE
	}
	if s.failed_baseline > 0 {
		return EXIT_BASELINE
	}
	if s.failed_regressions > 0 {
		return EXIT_FAILURE
	}
	return EXIT_SUCCESS
}

// Runs the suite and writes report files, without printing. Expects the caller to have set
// `context.temp_allocator` to scratch memory.
@(private)
_suite_execute :: proc(s: ^Suite) -> bool {
	_clear_results(s)
	if s.config.count_iterations > 0 {
		return _suite_count(s)
	}
	s.machine_state = read_machine_state(s.allocator)

	pinned: Thread_Pin
	if cpu, pin := s.config.pin_cpu.?; pin {
		ok: bool
		why: string
		pinned, ok, why = pin_thread(cpu)
		if !ok {
			fmt.eprintfln("obench: warning: not pinned to CPU %d: %s", cpu, why)
		}
	}
	defer unpin_thread(pinned)

	baseline_map := make(map[string]Stats, allocator = s.allocator)
	defer destroy_baseline_map(&baseline_map, s.allocator)

	baseline_loaded := false
	if s.config.test_mode && s.config.baseline_load_path != "" {
		fmt.eprintfln(
			"obench: --test doesn't measure, so baseline '%s' isn't compared",
			s.config.baseline_load_path,
		)
	}
	if s.config.baseline_load_path != "" && !s.config.test_mode {
		if doc, err := read_json_report(s.config.baseline_load_path, context.temp_allocator);
		   err != nil {
			fmt.eprintfln(
				"obench: could not read baseline '%s' (%v); continuing without comparison",
				s.config.baseline_load_path,
				err,
			)
			// Not a baseline to save again: the path may be misspelled.
			s.failed_io += 1
		} else {
			_fill_baseline_map(
				doc,
				&baseline_map,
				s.allocator,
				s.name,
				s.config.match_baseline_suite,
			)
			baseline_loaded = true

			// Times from another CPU model, or another machine, aren't this machine's times.
			if base_cpu, cpu := doc.machine.cpu, _cpu_model(); base_cpu != "" && base_cpu != cpu {
				fmt.eprintfln(
					"obench: warning: baseline '%s' was measured on %s and this run on %s",
					s.config.baseline_load_path,
					base_cpu,
					cpu if cpu != "" else "an unknown CPU",
				)
			} else if base_label, label := doc.machine.label, s.config.machine_label;
			   base_label != "" && label != "" && base_label != label {
				fmt.eprintfln(
					"obench: warning: baseline '%s' comes from machine '%s' and this run from '%s'",
					s.config.baseline_load_path,
					base_label,
					label,
				)
			}

			// A baseline from another -o mode or platform turns every delta into noise, and one
			// from an unoptimized build hides real regressions behind fake speedups.
			if base, current := _document_build(doc), _current_build();
			   _builds_differ(base, current) {
				fmt.eprintfln(
					"obench: warning: baseline '%s' was built with %s and this run with %s; their timings can't be compared",
					s.config.baseline_load_path,
					_build_string(base),
					_build_string(current),
				)
				if s.config.fail_on_regression {
					s.failed_baseline += 1
				}
			}

			// Counting allocations in every timed sample makes the benchmarks that allocate
			// slower, so a baseline counted the other way shows fake speedups or slowdowns.
			if untimed := s.config.untimed_alloc_check; doc.untimed_allocs != untimed {
				baseline_allocates := false
				for _, st in baseline_map {
					if _allocates(st.allocs_per_op, st.resizes_per_op, st.temp_allocs_per_op) {
						baseline_allocates = true
						break
					}
				}
				if baseline_allocates {
					fmt.eprintfln(
						"obench: warning: baseline '%s' counted allocations %s and this run %s; the times of benchmarks that allocate can't be compared (save the baseline again, or run with %s)",
						s.config.baseline_load_path,
						_alloc_counting_string(doc.untimed_allocs),
						_alloc_counting_string(untimed),
						_alloc_counting_flag(doc.untimed_allocs),
					)
					if s.config.fail_on_regression {
						s.failed_baseline += 1
					}
				}
			}
		}
	}

	counter_group: Counter_Group
	if s.config.counters {
		ok: bool
		why: string
		counter_group, ok, why = counter_group_open()
		if !ok {
			s.counters_unavailable = strings.clone(why, s.allocator)
		}
	}
	defer counter_group_close(&counter_group)

	filter := _name_pattern_make(s.config.filter, "--filter", s.allocator)
	defer _name_pattern_destroy(&filter, s.allocator)
	skip := _name_pattern_make(s.config.skip, "--skip", s.allocator)
	defer _name_pattern_destroy(&skip, s.allocator)
	selecting := s.config.filter != "" || s.config.skip != "" || s.config.exact != ""

	spall_rec: Spall_Recorder
	if !spall_recorder_init(&spall_rec, s.config.spall_export_path, s.allocator) {
		fmt.eprintfln("obench: could not create trace file '%s'", s.config.spall_export_path)
		s.failed_io += 1
	}
	defer spall_recorder_destroy(&spall_rec)

	// Benchmarks get a private temp arena so obench never resets the caller's
	// `context.temp_allocator` (which may hold strings the caller still needs).
	temp_arena := runtime.Arena {
		backing_allocator = s.allocator,
	}
	defer runtime.arena_destroy(&temp_arena)

	spall_begin(&spall_rec, s.name)

	for g in s.groups {
		spall_begin(&spall_rec, g.name)
		has_params := len(g.params) > 0
		param_count := has_params ? len(g.params) : 1

		has_threads := len(g.threads) > 0
		thread_count := has_threads ? len(g.threads) : 1

		group_res_start := len(s.results)

		for p_idx in 0 ..< param_count {
			param_val := has_params ? g.params[p_idx] : 0
			param_res_start := len(s.results)

			for t_idx in 0 ..< thread_count {
				thread_val := has_threads ? g.threads[t_idx] : 1
				cohort_start := len(s.results)

				for entry in g.entries {
					if selecting {
						name := format_full_name(
							g.name,
							entry.name,
							param_val,
							has_params,
							thread_val,
							has_threads,
							context.temp_allocator,
						)
						if !_selected(name, &filter, &skip, s.config.exact) {
							continue
						}
					}
					res := _execute_entry(
						s,
						g.name,
						entry,
						param_val,
						has_params,
						thread_val,
						has_threads,
						baseline_map,
						&spall_rec,
						&temp_arena,
						&counter_group,
					)
					append(&s.results, res)
				}

				_compute_speedups(s.results[cohort_start:])
			}

			// Thread-scaling group with a single entry: compare every thread count against the
			// first one, for the same parameter.
			if has_threads && len(g.entries) == 1 {
				_compute_speedups(s.results[param_res_start:])
			}
		}
		group_res_end := len(s.results)

		// Estimate Big-O complexity for each entry of parameterized groups.
		if has_params && len(g.params) >= 3 && !has_threads {
			for entry in g.entries {
				e_params := make([dynamic]int, 0, len(g.params), context.temp_allocator)
				e_times := make([dynamic]f64, 0, len(g.params), context.temp_allocator)
				for idx in group_res_start ..< group_res_end {
					r := &s.results[idx]
					if r.name == entry.name && r.has_param && r.error == .None {
						append(&e_params, r.param)
						append(&e_times, r.stats.p50_ns)
					}
				}
				if est, ok := estimate_complexity(g.name, entry.name, e_params[:], e_times[:]);
				   ok {
					append(&s.complexities, est)
				}
			}
		}

		spall_end(&spall_rec)
	}

	spall_end(&spall_rec)

	// A baseline that covers none of this suite's benchmarks compares nothing, so a regression
	// gate would pass without checking anything (a renamed suite, or the wrong file).
	if baseline_loaded && len(s.results) > 0 {
		matched := false
		for &r in s.results {
			if r.full_name in baseline_map {
				matched = true
				break
			}
		}
		if !matched {
			fmt.eprintfln(
				"obench: warning: no benchmark of suite '%s' is in baseline '%s'; nothing was compared",
				s.name,
				s.config.baseline_load_path,
			)
			if s.config.fail_on_regression || s.config.fail_on_alloc_regression {
				s.failed_baseline += 1
			}
		}
	}

	// Too few samples on a side for a 95% interval decide nothing, so a regression gate would
	// pass those benchmarks without checking them.
	if baseline_loaded {
		undecided := 0
		for &r in s.results {
			if r.diff.too_few_samples {
				undecided += 1
			}
		}
		if undecided > 0 {
			fmt.eprintfln(
				"obench: warning: %d benchmark(s) have too few samples in baseline '%s' or in this run for a 95%% interval, so nothing was decided for them",
				undecided,
				s.config.baseline_load_path,
			)
			if s.config.fail_on_regression {
				s.failed_baseline += 1
			}
		}
	}

	if len(s.results) > 0 && !s.config.test_mode {
		s.empty_loop_ns = _time_empty_loop(s, &temp_arena)
	}

	s.summary = compute_suite_summary(s.results[:])

	// A filter that matches nothing here (a typo, or a benchmark of another suite) must not
	// replace a saved baseline or report with an empty one.
	if len(s.results) == 0 && selecting {
		return suite_failure_count(s) == 0
	}

	if s.config.test_mode && s.config.baseline_save_path != "" {
		fmt.eprintfln(
			"obench: --test doesn't measure, so baseline '%s' isn't saved",
			s.config.baseline_save_path,
		)
	} else {
		_write_report_file(s, s.config.baseline_save_path, "baseline", save_json_report)
	}
	_write_report_file(s, s.config.json_export_path, "JSON", save_json_report)
	_write_report_file(s, s.config.md_export_path, "Markdown", save_markdown_report)
	_write_report_file(s, s.config.csv_export_path, "CSV", save_csv_report)
	_write_report_file(s, s.config.html_export_path, "HTML", save_html_report)

	return suite_failure_count(s) == 0
}

// A `--filter` or `--skip` pattern. A name matches it when the name contains the text, or when
// the text is a regular expression that matches part of the name, so the plain substrings
// that filters were before still select the same benchmarks.
@(private = "file")
_Name_Pattern :: struct {
	text:     string,
	regex:    regex.Regular_Expression,
	is_regex: bool,
}

@(private = "file")
_name_pattern_make :: proc(
	text: string,
	flag: string,
	allocator: runtime.Allocator,
) -> _Name_Pattern {
	p := _Name_Pattern {
		text = text,
	}
	if text == "" {
		return p
	}
	re, err := regex.create(text, {}, allocator, context.temp_allocator)
	if err != nil && flag != "" {
		fmt.eprintfln(
			"obench: %s '%s' isn't a regular expression (%v), so it only matches as plain text",
			flag,
			text,
			err,
		)
		return p
	}
	if err != nil {
		return p
	}
	p.regex = re
	p.is_regex = true
	return p
}

@(private = "file")
_name_pattern_destroy :: proc(p: ^_Name_Pattern, allocator: runtime.Allocator) {
	if p.is_regex {
		regex.destroy_regex(p.regex, allocator)
	}
	p^ = {}
}

@(private = "file")
_name_pattern_matches :: proc(p: ^_Name_Pattern, name: string) -> bool {
	if strings.contains(name, p.text) {
		return true
	}
	if !p.is_regex {
		return false
	}
	capture, matched := regex.match_and_allocate_capture(
		p.regex,
		name,
		context.temp_allocator,
		context.temp_allocator,
	)
	regex.destroy_capture(capture, context.temp_allocator)
	return matched
}

// Whether `--filter`, `--skip`, and `--exact` let the benchmark called `name` run.
@(private = "file")
_selected :: proc(name: string, filter, skip: ^_Name_Pattern, exact: string) -> bool {
	if exact != "" && name != exact {
		return false
	}
	if filter.text != "" && !_name_pattern_matches(filter, name) {
		return false
	}
	if skip.text != "" && _name_pattern_matches(skip, name) {
		return false
	}
	return true
}

@(private = "file")
_empty_step :: proc(b: ^Bencher) {
	for step(b) {
	}
}

@(private = "file")
_black_box_step :: proc(b: ^Bencher) {
	for step(b) {
		_ = black_box(0)
	}
}

// Times an empty `step` loop, and the same loop with a `black_box` in its body, with the
// suite's settings and at most 20 samples each. Returns the lower of the two median times per
// iteration, or 0 if both failed. The empty loop isn't always the faster one: every iteration
// loads the counter that the iteration before stored, and on some CPUs (an Apple M2 for one)
// that costs more when nothing else sits between the store and the load.
@(private = "file")
_time_empty_loop :: proc(s: ^Suite, temp_arena: ^runtime.Arena) -> f64 {
	saved := s.config
	defer s.config = saved
	s.config.sample_count = min(s.config.sample_count, 20)
	s.config.warmup_time = min(s.config.warmup_time, 10 * time.Millisecond)
	s.config.enforce_zero_allocs = false
	// `fixed_batch_size` is for the benchmarks: a small one would leave the loop a tick or two
	// of the clock per sample.
	s.config.fixed_batch_size = 0

	no_baseline: map[string]Stats
	no_trace: Spall_Recorder
	floor: f64 = 0
	for procedure in ([2]Bench_Proc{_empty_step, _black_box_step}) {
		res := _execute_entry(
			s,
			"",
			Entry{name = "empty loop", procedure = procedure},
			0,
			false,
			1,
			false,
			no_baseline,
			&no_trace,
			temp_arena,
		)
		if res.error == .None && res.stats.p50_ns > 0 && (floor == 0 || res.stats.p50_ns < floor) {
			floor = res.stats.p50_ns
		}
		_destroy_result(s, &res)
	}
	return floor
}

// `Config.count_iterations`: runs every selected benchmark with one iteration, which checks
// that it uses the `Bencher` correctly, and then with `count_iterations`, and does nothing
// else that could make two runs do different work.
@(private = "file")
_suite_count :: proc(s: ^Suite) -> bool {
	filter := _name_pattern_make(s.config.filter, "--filter", s.allocator)
	defer _name_pattern_destroy(&filter, s.allocator)
	skip := _name_pattern_make(s.config.skip, "--skip", s.allocator)
	defer _name_pattern_destroy(&skip, s.allocator)
	temp_arena := runtime.Arena {
		backing_allocator = s.allocator,
	}
	defer runtime.arena_destroy(&temp_arena)

	for g in s.groups {
		param_count := max(len(g.params), 1)
		thread_count := max(len(g.threads), 1)
		for p_idx in 0 ..< param_count {
			param := g.params[p_idx] if len(g.params) > 0 else 0
			for t_idx in 0 ..< thread_count {
				threads := g.threads[t_idx] if len(g.threads) > 0 else 1
				for entry in g.entries {
					name := format_full_name(
						g.name,
						entry.name,
						param,
						len(g.params) > 0,
						threads,
						len(g.threads) > 0,
						context.temp_allocator,
					)
					if !_selected(name, &filter, &skip, s.config.exact) {
						continue
					}
					info := _Run_Info {
						entry       = entry,
						group_name  = g.name,
						param       = param,
						has_param   = len(g.params) > 0,
						threads     = threads,
						has_threads = len(g.threads) > 0,
						temp_arena  = &temp_arena,
					}
					for iterations in ([2]int{1, s.config.count_iterations}) {
						br := _run_batch(&info, iterations, nil, nil)
						runtime.arena_free_all(&temp_arena)
						if br.error != .None {
							fmt.eprintfln("obench: %s: %s", name, bench_error_message(br.error))
							s.failed_errors += 1
							break
						}
					}
				}
			}
		}
	}
	return suite_failure_count(s) == 0
}

/*
Whether `cfg`'s `filter`, `skip`, and `exact` select the benchmark with the full name `name`,
the way `suite_run` decides it.
*/
@(require_results)
benchmark_selected :: proc(cfg: Config, name: string) -> bool {
	// No flag name, so an invalid pattern isn't reported once per benchmark.
	filter := _name_pattern_make(cfg.filter, "", context.temp_allocator)
	skip := _name_pattern_make(cfg.skip, "", context.temp_allocator)
	return _selected(name, &filter, &skip, cfg.exact)
}

/*
Bytes to move the stack down before the benchmarks run, from `OBENCH_STACK_OFFSET` (at most
64 KiB). `obench --count` gives every process a random one, so the processes don't all share
one stack layout, which can make one of them faster or slower for reasons unrelated to the
code (Mytkowicz et al., "Producing Wrong Data Without Doing Anything Obviously Wrong!").
*/
@(private = "file")
_stack_offset :: proc() -> int {
	n, ok := strconv.parse_int(os.get_env("OBENCH_STACK_OFFSET", context.temp_allocator))
	return clamp(n, 0, 64 << 10) if ok else 0
}
