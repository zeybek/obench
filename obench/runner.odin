package obench

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
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
	custom_metrics:       [MAX_CUSTOM_METRICS]Custom_Metric,
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
		heap_counter.enforce_zero_allocs = b.expect_zero_alloc
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

	if !b._started_sample {
		res.error = .No_Measurement
	} else if !b._finished && b.remaining_iters > 0 {
		res.error = .Loop_Exited_Early
	}

	res.ns = b._accum_ns
	res.cycles = b._accum_cycles
	res.windows = b._windows
	res.bytes_per_op = b.bytes_per_op
	res.items_per_op = b.items_per_op
	res.expect_zero = b.expect_zero_alloc
	res.custom_metrics = b.custom_metrics
	res.custom_metrics_count = b.custom_metrics_count
	return
}

@(private = "file")
_fail_entry :: proc(s: ^Suite, result: ^Result, err: Bench_Error) -> Result {
	result.error = err
	s.failed_errors += 1
	return result^
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

		warmup_budget := i64(cfg.warmup_time)
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
	batch_size := cfg.fixed_batch_size
	if batch_size <= 0 {
		spall_begin(spall_rec, "calibrate")
		defer spall_end(spall_rec)

		target_ns := max(i64(cfg.min_sample_time), 50_000)
		probe_batch := 1
		for {
			br := _run_batch(&info, probe_batch, nil, nil)
			if cfg.reset_temp_per_iter {
				runtime.arena_free_all(temp_arena)
			}
			if br.error != .None {
				return _fail_entry(s, &result, br.error)
			}
			ns := br.ns
			if ns >= target_ns || probe_batch >= 10_000_000 {
				if ns > 0 {
					estimated := int((f64(target_ns) / f64(ns)) * f64(probe_batch))
					batch_size = clamp(estimated, 1, 10_000_000)
				} else {
					batch_size = probe_batch
				}
				break
			}
			if ns <= 0 {
				probe_batch *= 10
			} else {
				ratio := int(target_ns / max(ns, 1))
				probe_batch *= clamp(ratio, 2, 16)
			}
		}
	}

	// 3. Sample collection with allocation tracking.
	sample_target := max(cfg.sample_count, 5)
	ns_samples := make([dynamic]f64, 0, sample_target, s.allocator)
	defer delete(ns_samples)
	cyc_samples := make([dynamic]f64, 0, sample_target, s.allocator)
	defer delete(cyc_samples)

	heap_counter: Counting_Allocator
	temp_counter: Counting_Allocator
	counting_allocator_init(&heap_counter, context.allocator)
	counting_allocator_init(&temp_counter, runtime.arena_allocator(temp_arena))

	total_iters: u64 = 0
	max_bench_ns := i64(cfg.max_bench_time)
	bytes_per_op: u64 = 0
	items_per_op: u64 = 0

	// Custom metric units are copied before the arena reset, because a unit string may
	// have been formatted with `context.temp_allocator` inside the benchmark.
	last_custom: [MAX_CUSTOM_METRICS]Custom_Metric
	last_custom_count := 0
	defer {
		for i in 0 ..< last_custom_count {
			delete(last_custom[i].unit, s.allocator)
		}
	}

	arg_buf: [48]u8
	batch_arg := fmt.bprintf(arg_buf[:], "batch=%d", batch_size)
	sampling_start := time.tick_now()
	for i := 0; i < sample_target; i += 1 {
		spall_begin(spall_rec, "sample", batch_arg)
		br := _run_batch(&info, batch_size, &heap_counter, &temp_counter)
		spall_end(spall_rec)

		if br.custom_metrics_count > 0 {
			for j in 0 ..< last_custom_count {
				delete(last_custom[j].unit, s.allocator)
			}
			last_custom_count = br.custom_metrics_count
			for j in 0 ..< last_custom_count {
				last_custom[j] = Custom_Metric {
					unit  = strings.clone(br.custom_metrics[j].unit, s.allocator),
					value = br.custom_metrics[j].value,
				}
			}
		}
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
		adj_ns := max(f64(br.ns) - s.clock.overhead_ns * windows, 0)
		adj_cyc := max(f64(br.cycles) - s.clock.overhead_cycles * windows, 0)

		append(&ns_samples, adj_ns / f64(batch_size))
		append(&cyc_samples, adj_cyc / f64(batch_size))
		total_iters += u64(batch_size)

		if i + 1 >= MIN_SAMPLES &&
		   max_bench_ns > 0 &&
		   i64(time.tick_since(sampling_start)) >= max_bench_ns {
			break
		}
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
	)
	st.samples_ns = slice.clone(ns_samples[:], s.allocator)
	last_custom_count = 0 // Ownership of the unit strings moves to the result.

	if base_st, ok := baseline_map[full_name]; ok {
		result.diff = compare_baseline(st, base_st, cfg.noise_threshold_pct)
		if result.diff.is_regression && cfg.fail_on_regression {
			s.failed_regressions += 1
		}
	}

	result.stats = st
	result.zero_alloc_failed = expect_zero && heap_counter.zero_alloc_violated
	if result.zero_alloc_failed {
		s.failed_zero_alloc += 1
		result.violation_loc = heap_counter.first_violation_loc
		result.violation_size = heap_counter.first_violation_size
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

	ref := results[0]
	fastest_ns := max(f64)
	for r in results {
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

	ok := _suite_execute(s)
	print_terminal_report(s)
	return ok
}

/*
Number of problems found by the last `suite_run` or `run_test`: misused benchmarks, failed
`@zero_alloc` checks, regressions that fail the run, and unreadable or unwritable files.
*/
@(require_results)
suite_failure_count :: proc "contextless" (s: ^Suite) -> int {
	return s.failed_zero_alloc + s.failed_regressions + s.failed_errors + s.failed_io
}

// Runs the suite and writes report files, without printing. Expects the caller to have set
// `context.temp_allocator` to scratch memory.
@(private)
_suite_execute :: proc(s: ^Suite) -> bool {
	_clear_results(s)

	baseline_map := make(map[string]Stats, allocator = s.allocator)
	defer destroy_baseline_map(&baseline_map, s.allocator)

	if s.config.baseline_load_path != "" {
		if err := load_baseline_file(
			s.config.baseline_load_path,
			&baseline_map,
			s.allocator,
			s.name,
		); err != nil {
			fmt.eprintfln(
				"obench: could not read baseline '%s' (%v); continuing without comparison",
				s.config.baseline_load_path,
				err,
			)
			s.failed_io += 1
		}
	}

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

			for t_idx in 0 ..< thread_count {
				thread_val := has_threads ? g.threads[t_idx] : 1
				cohort_start := len(s.results)

				for entry in g.entries {
					if s.config.filter != "" {
						probe := format_full_name(
							g.name,
							entry.name,
							param_val,
							has_params,
							thread_val,
							has_threads,
							context.temp_allocator,
						)
						if !strings.contains(probe, s.config.filter) {
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
					)
					append(&s.results, res)
				}

				_compute_speedups(s.results[cohort_start:])
			}
		}

		// Thread-scaling group with a single entry: compare every thread count against the first.
		group_res_end := len(s.results)
		if has_threads && len(g.entries) == 1 {
			_compute_speedups(s.results[group_res_start:group_res_end])
		}

		// Estimate Big-O complexity for each entry of parameterized groups.
		if has_params && len(g.params) >= 3 && !has_threads {
			for entry in g.entries {
				e_params := make([dynamic]int, 0, len(g.params), context.temp_allocator)
				e_times := make([dynamic]f64, 0, len(g.params), context.temp_allocator)
				for idx in group_res_start ..< group_res_end {
					r := s.results[idx]
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

	s.summary = compute_suite_summary(s.results[:])

	_write_report_file(s, s.config.baseline_save_path, "baseline", save_json_report)
	_write_report_file(s, s.config.json_export_path, "JSON", save_json_report)
	_write_report_file(s, s.config.md_export_path, "Markdown", save_markdown_report)
	_write_report_file(s, s.config.csv_export_path, "CSV", save_csv_report)

	return suite_failure_count(s) == 0
}
