package obench_tests

import obench "../obench"
import "base:intrinsics"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"

// A small, fast configuration for suites run inside tests.
@(private = "file")
quick_config :: proc() -> obench.Config {
	return obench.Config {
		warmup_time = 1 * time.Millisecond,
		min_sample_time = 50 * time.Microsecond,
		max_bench_time = 50 * time.Millisecond,
		sample_count = 10,
		fixed_batch_size = 16,
		reset_temp_per_iter = true,
		noise_threshold_pct = 2.0,
		color_output = false,
		show_histogram = true,
	}
}

@(private = "file")
_noop_step :: proc(b: ^obench.Bencher) {
	for obench.step(b) {
		_ = obench.black_box(1)
	}
}

// ---------------------------------------------------------------------------
// Optimization barriers
// ---------------------------------------------------------------------------

@(test)
test_black_box_preserves_values :: proc(t: ^testing.T) {
	testing.expect_value(t, obench.black_box(42), 42)
	testing.expect_value(t, obench.black_box(f32(1.5)), f32(1.5))
	testing.expect_value(t, obench.black_box(true), true)

	Color :: enum {
		Red,
		Green,
	}
	testing.expect_value(t, obench.black_box(Color.Green), Color.Green)

	Vec3 :: struct {
		x, y, z: f32,
	}
	v := obench.black_box(Vec3{1.5, 2.5, 3.5})
	testing.expect_value(t, v, Vec3{1.5, 2.5, 3.5})

	lanes := obench.black_box(#simd[4]f32{1, 2, 3, 4})
	arr := transmute([4]f32)lanes
	testing.expect_value(t, arr, [4]f32{1, 2, 3, 4})

	x := 7
	p := obench.black_box(&x)
	testing.expect_value(t, p^, 7)

	s := obench.black_box("hello")
	testing.expect_value(t, s, "hello")

	fixed := [4]int{10, 20, 30, 40}
	obench.keep_alive(&fixed)
	testing.expect_value(t, fixed[2], 30)
}

// ---------------------------------------------------------------------------
// Counting allocator
// ---------------------------------------------------------------------------

@(test)
test_counting_allocator_tracks_allocs_and_pause :: proc(t: ^testing.T) {
	ca: obench.Counting_Allocator
	obench.counting_allocator_init(&ca, context.allocator)
	alloc := obench.counting_allocator(&ca)

	buf1, err1 := make([]byte, 128, alloc)
	testing.expect_value(t, err1, nil)
	testing.expect_value(t, ca.alloc_count, u64(1))
	testing.expect_value(t, ca.bytes_allocated, u64(128))
	testing.expect_value(t, ca.current_bytes, i64(128))
	testing.expect_value(t, ca.peak_bytes, i64(128))

	obench.counting_allocator_set_paused(&ca, true)
	buf2, err2 := make([]byte, 256, alloc)
	testing.expect_value(t, err2, nil)
	testing.expect_value(t, ca.alloc_count, u64(1))
	testing.expect_value(t, ca.bytes_allocated, u64(128))
	delete(buf2, alloc)
	obench.counting_allocator_set_paused(&ca, false)

	delete(buf1, alloc)
	testing.expect_value(t, ca.free_count, u64(1))
	testing.expect_value(t, ca.bytes_freed, u64(128))
	testing.expect_value(t, ca.current_bytes, i64(0))
}

@(test)
test_counting_allocator_counts_resizes :: proc(t: ^testing.T) {
	ca: obench.Counting_Allocator
	obench.counting_allocator_init(&ca, context.allocator)
	alloc := obench.counting_allocator(&ca)

	arr := make([dynamic]int, 0, 1, alloc)
	for i in 0 ..< 64 {
		append(&arr, i)
	}
	testing.expect_value(t, ca.alloc_count, u64(1))
	testing.expect(
		t,
		ca.resize_count >= 3,
		"growing a dynamic array from capacity 1 to 64 must resize",
	)
	testing.expect_value(t, ca.bytes_allocated, u64(cap(arr) * size_of(int)))
	delete(arr)
	testing.expect_value(t, ca.current_bytes, i64(0))
}

@(test)
test_counting_allocator_zero_alloc_violation :: proc(t: ^testing.T) {
	ca: obench.Counting_Allocator
	obench.counting_allocator_init(&ca, context.allocator)
	ca.enforce_zero_allocs = true
	alloc := obench.counting_allocator(&ca)

	buf, err := make([]byte, 64, alloc)
	testing.expect_value(t, err, nil)
	testing.expect(t, ca.zero_alloc_violated, "expected zero_alloc_violated to be true")
	testing.expect_value(t, ca.first_violation_size, 64)
	delete(buf, alloc)
}

// ---------------------------------------------------------------------------
// Statistics
// ---------------------------------------------------------------------------

@(test)
test_stats_computation_and_baseline_diff :: proc(t: ^testing.T) {
	samples_ns := []f64{100.0, 102.0, 98.0, 101.0, 99.0, 100.0, 100.5, 99.5, 101.5, 98.5}
	samples_cyc := []f64{300.0, 306.0, 294.0, 303.0, 297.0, 300.0, 301.5, 298.5, 304.5, 295.5}

	st := obench.compute_stats(samples_ns, samples_cyc, 10, 100, 1024, 1, nil, nil)
	testing.expect_value(t, st.samples, 10)
	testing.expect_value(t, st.min_ns, 98.0)
	testing.expect_value(t, st.max_ns, 102.0)
	testing.expect_value(t, st.p50_ns, 100.0)
	testing.expect(t, st.ci95_ns > 0.0, "expected positive 95% confidence interval")
	testing.expect(t, st.mb_per_sec > 9000.0, "expected throughput > 9000 MiB/s")

	slower_ns := []f64{120.0, 122.0, 118.0, 121.0, 119.0, 120.0, 120.5, 119.5, 121.5, 118.5}
	st_slow := obench.compute_stats(slower_ns, samples_cyc, 10, 100, 1024, 1, nil, nil)

	diff := obench.compare_baseline(st_slow, st, 2.0)
	testing.expect(t, diff.has_baseline, "expected has_baseline")
	testing.expect(t, diff.is_significant, "expected significant diff")
	testing.expect(t, diff.is_regression, "expected regression (+20%)")
	testing.expect(
		t,
		abs(diff.welch_df - 18.0) < 0.5,
		"equal variances and sizes give df close to 2n-2",
	)

	same := obench.compare_baseline(st, st, 2.0)
	testing.expect(t, !same.is_significant, "identical stats must not be significant")
}

@(test)
test_mann_whitney_u_reference_values :: proc(t: ^testing.T) {
	// Normal approximation with continuity correction (scipy.stats.mannwhitneyu,
	// method="asymptotic").
	u, z, p := obench.mann_whitney_u([]f64{1, 2, 3}, []f64{4, 5, 6})
	testing.expect_value(t, u, 0.0)
	testing.expectf(t, abs(z + 1.7457) < 1e-3, "z %v", z)
	testing.expectf(t, abs(p - 0.0809) < 1e-3, "p %v", p)

	// Ties share their average rank and shrink the variance.
	u, z, p = obench.mann_whitney_u([]f64{1, 2, 2, 3}, []f64{2, 3, 3, 4})
	testing.expect_value(t, u, 3.0)
	testing.expectf(t, abs(z + 1.3657) < 1e-3, "z %v", z)
	testing.expectf(t, abs(p - 0.1720) < 1e-3, "p %v", p)

	_, _, p = obench.mann_whitney_u([]f64{5, 5, 5}, []f64{5, 5})
	testing.expect_value(t, p, 1.0)
}

@(test)
test_rank_test_sees_a_shift_hidden_by_outliers :: proc(t: ^testing.T) {
	// The baseline's p99 is eight times its median, which inflates the standard deviation
	// so much that Welch's t-test misses an 85% slower median.
	base_ns := make([]f64, 50, context.temp_allocator)
	slow_ns := make([]f64, 50, context.temp_allocator)
	for i in 0 ..< 50 {
		jitter := f64(i % 5) * 0.1
		base_ns[i] = i < 45 ? 100 + jitter : 800 + jitter
		slow_ns[i] = i < 45 ? 185 + jitter : 800 + jitter
	}
	base := obench.compute_stats(base_ns, base_ns, 1, 50, 0, 0, nil, nil)
	slow := obench.compute_stats(slow_ns, slow_ns, 1, 50, 0, 0, nil, nil)

	diff := obench.compare_baseline(slow, base, 2.0)
	testing.expectf(t, diff.delta_median_pct > 80, "median delta %v", diff.delta_median_pct)
	testing.expect(t, diff.is_regression, "an 85% slower median must count as a regression")

	same := obench.compare_baseline(base, base, 2.0)
	testing.expect(t, !same.is_significant, "identical samples must not be significant")

	// A report from before format version 3 has no samples: Welch's t-test decides, and
	// the outliers hide the shift from it.
	old_base := base
	old_base.samples_ns = nil
	old := obench.compare_baseline(slow, old_base, 2.0)
	testing.expect(t, !old.rank_test)
	testing.expect(t, !old.is_regression, "Welch's t-test on these samples is not significant")
}

@(test)
test_t_critical_values :: proc(t: ^testing.T) {
	// Reference values of the two-sided 5% Student's t critical value.
	cases := [?][2]f64 {
		{1, 12.706},
		{2, 4.303},
		{3, 3.182},
		{5, 2.571},
		{10, 2.228},
		{30, 2.042},
		{100, 1.984},
	}
	for c in cases {
		got := obench.t_critical_975(c[0])
		testing.expectf(t, abs(got - c[1]) < 0.001, "df=%v: got %v, want %v", c[0], got, c[1])
	}
	testing.expect(
		t,
		abs(obench.t_critical_975(1e9) - 1.96) < 0.001,
		"large df approaches the normal quantile",
	)
}

@(test)
test_bigo_complexity_estimation :: proc(t: ^testing.T) {
	params := []int{8, 64, 512, 4096}

	est_o1, ok1 := obench.estimate_complexity(
		"grp",
		"const_lookup",
		params,
		[]f64{3.1, 3.15, 3.12, 3.18},
	)
	testing.expect(t, ok1)
	testing.expect_value(t, est_o1.best_class, obench.Complexity_Class.O_1)

	est_log, ok2 := obench.estimate_complexity(
		"grp",
		"bin_search",
		params,
		[]f64{6.0, 12.0, 18.0, 24.0},
	)
	testing.expect(t, ok2)
	testing.expect_value(t, est_log.best_class, obench.Complexity_Class.O_Log_N)

	est_on, ok3 := obench.estimate_complexity(
		"grp",
		"linear_scan",
		params,
		[]f64{8.0, 64.0, 512.0, 4096.0},
	)
	testing.expect(t, ok3)
	testing.expect_value(t, est_on.best_class, obench.Complexity_Class.O_N)

	est_n2, ok4 := obench.estimate_complexity(
		"grp",
		"bubble_sort",
		[]int{10, 20, 40, 80},
		[]f64{100.0, 400.0, 1600.0, 6400.0},
	)
	testing.expect(t, ok4)
	testing.expect_value(t, est_n2.best_class, obench.Complexity_Class.O_N2)

	_, ok5 := obench.estimate_complexity("grp", "repeated", []int{8, 8, 64, 64}, []f64{1, 1, 2, 2})
	testing.expect(t, !ok5, "fewer than 3 distinct parameters cannot be fitted")
}

@(test)
test_bigo_with_a_constant_cost :: proc(t: ^testing.T) {
	// 50 ns of fixed cost plus 0.01 ns per element.
	params := []int{8, 64, 512, 4096, 32768}
	times := make([]f64, len(params), context.temp_allocator)
	for p, i in params {
		times[i] = 50 + 0.01 * f64(p)
	}
	est, ok := obench.estimate_complexity("grp", "linear_with_setup", params, times)
	testing.expect(t, ok)
	testing.expect_value(t, est.best_class, obench.Complexity_Class.O_N)
	testing.expectf(t, est.nrmse < 0.001, "an exact a + c*N curve must fit, NRMSE %v", est.nrmse)
	testing.expectf(t, abs(est.intercept - 50) < 1e-6, "intercept %v", est.intercept)
	testing.expectf(t, abs(est.coefficient - 0.01) < 1e-9, "coefficient %v", est.coefficient)

	// When the fixed cost dominates, the growth is still there.
	small_params := []int{8, 64, 512, 4096}
	setup_heavy := make([]f64, len(small_params), context.temp_allocator)
	for p, i in small_params {
		setup_heavy[i] = 200 + 0.01 * f64(p)
	}
	heavy, heavy_ok := obench.estimate_complexity("grp", "setup_heavy", small_params, setup_heavy)
	testing.expect(t, heavy_ok)
	testing.expect_value(t, heavy.best_class, obench.Complexity_Class.O_N)
}

@(test)
test_clock_overhead_is_measured :: proc(t: ^testing.T) {
	// Two clock reads always cost something, even when the clock ticks too coarsely to
	// see a single pair.
	cal := obench.clock_calibrate()
	testing.expectf(t, cal.overhead_ns > 0, "overhead %v ns", cal.overhead_ns)
	testing.expectf(t, cal.overhead_ns < 10_000, "overhead %v ns", cal.overhead_ns)
}

@(test)
test_long_environment_values_are_read :: proc(t: ^testing.T) {
	long_path := strings.concatenate(
		{strings.repeat("d", 1500, context.temp_allocator), ".json"},
		context.temp_allocator,
	)
	testing.expect_value(t, os.set_env("OBENCH_MD", long_path), nil)
	defer os.unset_env("OBENCH_MD")
	cfg := obench.default_config()
	testing.expect_value(t, cfg.md_export_path, long_path)
}

// ---------------------------------------------------------------------------
// Terminal formatting
// ---------------------------------------------------------------------------

// Strips ANSI escape sequences and returns the display columns of every '│' in `line`.
@(private = "file")
_separator_columns :: proc(line: string) -> [dynamic]int {
	cols := make([dynamic]int, context.temp_allocator)
	col := 0
	in_escape := false
	for r in line {
		switch {
		case in_escape:
			in_escape = !((r >= 'A' && r <= 'Z') || (r >= 'a' && r <= 'z'))
		case r == 0x1b:
			in_escape = true
		case:
			if r == '│' {
				append(&cols, col)
			}
			col += 1
		}
	}
	return cols
}

@(test)
test_terminal_report_columns_line_up :: proc(t: ^testing.T) {
	cfg := quick_config()
	cfg.color_output = true // ANSI codes must not shift the columns
	s := obench.suite_create("alignment", cfg)
	defer obench.suite_destroy(&s)
	g := obench.group_add(&s, "grp")
	obench.group_bench(g, "a_rather_long_benchmark_name", _noop_step)
	obench.group_bench(g, "short", _noop_step)
	obench.group_bench(g, "broken", _never_steps)
	_ = obench.suite_run(&s)

	sb := strings.builder_make(context.temp_allocator)
	obench.write_terminal_report(strings.to_writer(&sb), &s)

	expected: [dynamic]int
	rows := 0
	report := strings.to_string(sb)
	for line in strings.split_lines_iterator(&report) {
		if strings.contains(line, "PASS:") || strings.contains(line, "FAIL:") {
			continue // the summary line uses '│' as a plain separator
		}
		cols := _separator_columns(line)
		if len(cols) == 0 {
			continue
		}
		if rows == 0 {
			expected = cols
		} else {
			testing.expectf(
				t,
				slice.equal(cols[:], expected[:]),
				"row %q has separators at %v, header at %v",
				line,
				cols[:],
				expected[:],
			)
		}
		rows += 1
	}
	testing.expect_value(t, rows, 4) // header + 3 benchmarks
}

// ---------------------------------------------------------------------------
// Command-line flags inside benchmark programs
// ---------------------------------------------------------------------------

@(test)
test_apply_args :: proc(t: ^testing.T) {
	cfg := quick_config()
	obench.apply_args(
		&cfg,
		[]string {
			"--filter=sort",
			"-n:7",
			"--my-own-flag",
			"x",
			"--warmup",
			"3",
			"--zero-alloc",
			"--json",
			"out.json",
			"--no-histogram",
		},
	)
	testing.expect_value(t, cfg.filter, "sort")
	testing.expect_value(t, cfg.sample_count, 7)
	testing.expect_value(t, cfg.warmup_time, 3 * time.Millisecond)
	testing.expect_value(t, cfg.enforce_zero_allocs, true)
	testing.expect_value(t, cfg.json_export_path, "out.json")
	testing.expect_value(t, cfg.show_histogram, false)
}

// ---------------------------------------------------------------------------
// Suite behavior
// ---------------------------------------------------------------------------

@(private = "file")
_churn_temp_allocator :: proc(b: ^obench.Bencher) {
	for obench.step(b) {
		msg := fmt.tprintf(
			"%s-%d",
			"temporary string that overwrites temp memory",
			obench.black_box(12345),
		)
		obench.keep_alive(&msg)
	}
}

@(test)
test_config_and_caller_temp_strings_survive_run :: proc(t: ^testing.T) {
	// Paths allocated with the temp allocator, like `default_config` does for OBENCH_* variables.
	json_path := fmt.tprintf(".obench_test_temp_lifetime_%d.json", 1)
	caller_note := strings.clone("caller data in temp memory", context.temp_allocator)
	defer os.remove(".obench_test_temp_lifetime_1.json")

	cfg := quick_config()
	cfg.json_export_path = json_path
	cfg.filter = strings.clone("churn", context.temp_allocator)

	s := obench.suite_create("temp_lifetime", cfg)
	defer obench.suite_destroy(&s)
	obench.bench(&s, "churn_a", _churn_temp_allocator)
	obench.bench(&s, "churn_b", _churn_temp_allocator)
	obench.bench(&s, "skipped_by_filter", _noop_step)

	testing.expect(t, obench.suite_run(&s))
	testing.expect_value(t, len(s.results), 2)
	testing.expect(
		t,
		os.exists(".obench_test_temp_lifetime_1.json"),
		"the JSON report must be written to the configured path",
	)
	testing.expect_value(t, caller_note, "caller data in temp memory")
}

@(test)
test_group_pointers_stay_valid :: proc(t: ^testing.T) {
	s := obench.suite_create("stable_groups", quick_config())
	defer obench.suite_destroy(&s)

	first := obench.group_add(&s, "first")
	for i in 0 ..< 40 {
		_ = obench.group_add(&s, fmt.tprintf("filler_%d", i))
	}
	obench.group_bench(first, "registered_late", _noop_step)

	testing.expect(t, obench.suite_run(&s))
	testing.expect_value(t, len(s.results), 1)
	testing.expect_value(t, s.results[0].full_name, "first::registered_late")
}

@(test)
test_bench_reuses_default_group :: proc(t: ^testing.T) {
	s := obench.suite_create("default_group", quick_config())
	defer obench.suite_destroy(&s)

	_ = obench.group_add(&s, "other")
	obench.bench(&s, "a", _noop_step)
	obench.bench(&s, "b", _noop_step)
	testing.expect_value(t, len(s.groups), 2)
	testing.expect_value(t, len(s.groups[1].entries), 2)
}

@(private = "file")
_never_steps :: proc(b: ^obench.Bencher) {
}

@(private = "file")
_breaks_out :: proc(b: ^obench.Bencher) {
	for obench.step(b) {
		break
	}
}

@(test)
test_misuse_is_reported :: proc(t: ^testing.T) {
	cfg := quick_config()
	cfg.warmup_time = 40 * time.Millisecond // must not spin for the whole warmup
	s := obench.suite_create("misuse", cfg)
	defer obench.suite_destroy(&s)
	obench.bench(&s, "never_steps", _never_steps)
	obench.bench(&s, "breaks_out", _breaks_out)
	obench.bench(&s, "fine", _noop_step)

	start := time.tick_now()
	ok := obench.suite_run(&s)
	elapsed := time.tick_since(start)

	testing.expect(t, !ok, "misused benchmarks must fail the suite")
	testing.expect_value(t, s.failed_errors, 2)
	testing.expect_value(t, s.results[0].error, obench.Bench_Error.No_Measurement)
	testing.expect_value(t, s.results[1].error, obench.Bench_Error.Loop_Exited_Early)
	testing.expect_value(t, s.results[2].error, obench.Bench_Error.None)
	testing.expect(
		t,
		elapsed < 2 * time.Second,
		"a benchmark that never steps must be rejected immediately",
	)
}

@(private = "file")
_two_loops :: proc(b: ^obench.Bencher) {
	for obench.step(b) {
		_ = obench.black_box(1)
	}
	extra := 0
	for obench.step(b) {
		extra += 1
	}
	testing.expect_value((^testing.T)(b.user_ptr), extra, 0)
}

@(test)
test_second_step_loop_does_not_run :: proc(t: ^testing.T) {
	s := obench.suite_create("two_loops", quick_config())
	defer obench.suite_destroy(&s)
	obench.bench(&s, "two_loops", _two_loops, user_ptr = t)
	testing.expect(t, obench.suite_run(&s))
}

@(private = "file")
_appends :: proc(b: ^obench.Bencher) {
	for obench.step(b) {
		arr := make([dynamic]int, 0, 1)
		for i in 0 ..< 32 {
			append(&arr, i)
		}
		obench.keep_alive(&arr)
		delete(arr)
	}
}

@(private = "file")
_temp_metric_unit :: proc(b: ^obench.Bencher) {
	obench.report_metric(b, 42, fmt.tprintf("hits_%d", 7))
	for obench.step(b) {
		_ = obench.black_box(1)
	}
}

@(test)
test_allocation_and_metric_reporting :: proc(t: ^testing.T) {
	s := obench.suite_create("allocs", quick_config())
	defer obench.suite_destroy(&s)
	obench.bench(&s, "appends", _appends)
	obench.bench(&s, "metric", _temp_metric_unit)

	testing.expect(t, obench.suite_run(&s))
	st := s.results[0].stats
	testing.expect(
		t,
		st.resizes_per_op >= 3,
		"growth of a dynamic array must be counted as resizes",
	)
	testing.expect(
		t,
		abs(st.allocs_per_op - (1 + st.resizes_per_op)) < 1e-9,
		"allocs/op = allocations + resizes",
	)

	m := s.results[1].stats
	testing.expect_value(t, m.custom_metrics_count, 1)
	testing.expect_value(t, m.custom_metrics[0].unit, "hits_7")
	testing.expect_value(t, m.custom_metrics[0].value, 42.0)
}

@(private = "file")
_parallel_temp_allocs :: proc(b: ^obench.Bencher) {
	obench.run_parallel(b, proc(pb: ^obench.Parallel_Bencher) {
			for obench.parallel_next(pb) {
				buf := make([]u8, 16, context.temp_allocator)
				obench.keep_alive(&buf)
			}
		}, num_threads = 3)
}

@(test)
test_parallel_counts_worker_temp_allocations :: proc(t: ^testing.T) {
	cfg := quick_config()
	cfg.fixed_batch_size = 300
	s := obench.suite_create("parallel_temp", cfg)
	defer obench.suite_destroy(&s)
	obench.bench(&s, "temp", _parallel_temp_allocs)

	testing.expect(t, obench.suite_run(&s))
	got := s.results[0].stats.temp_allocs_per_op
	testing.expectf(
		t,
		abs(got - 1.0) < 1e-9,
		"every iteration on every thread allocates once from temp, got %v",
		got,
	)
}

@(private = "file")
_dummy_fast :: proc(b: ^obench.Bencher) {
	obench.expect_zero_allocs(b)
	obench.report_metric(b, 99.5, "hit%")
	acc := 0
	for obench.step(b) {
		acc += obench.black_box(1)
	}
	_ = obench.black_box(acc)
}

@(private = "file")
_dummy_alloc :: proc(b: ^obench.Bencher) {
	for obench.step(b) {
		{
			obench.scoped_pause(b)
			ignored := make([]u8, 128)
			delete(ignored)
		}
		slice_buf := make([]u8, 64)
		obench.keep_alive(&slice_buf)
		delete(slice_buf)
	}
}

@(private = "file")
_dummy_batched_sort :: proc(b: ^obench.Bencher) {
	obench.expect_zero_allocs(b)
	obench.iter_batched(b, setup = proc(b: ^obench.Bencher) -> []int {
			arr := make([]int, 16)
			for i in 0 ..< 16 {
				arr[i] = 16 - i
			}
			return arr
		}, routine = proc(arr: ^[]int) {
			slice.sort(arr^)
			obench.keep_alive(&arr^[0])
		}, teardown = proc(arr: ^[]int) {
			delete(arr^)
		})
}

@(private = "file")
_parallel_counter: i64

@(private = "file")
_dummy_parallel :: proc(b: ^obench.Bencher) {
	obench.expect_zero_allocs(b)
	intrinsics.atomic_store_explicit(&_parallel_counter, 0, .Relaxed)
	obench.run_parallel(b, proc(pb: ^obench.Parallel_Bencher) {
			for obench.parallel_next(pb) {
				_ = intrinsics.atomic_add_explicit(&_parallel_counter, 1, .Relaxed)
			}
		}, num_threads = 2)
}

@(test)
test_suite_lifecycle_exports_spall_and_compare :: proc(t: ^testing.T) {
	tmp_json := ".obench_test_baseline.json"
	tmp_csv := ".obench_test_report.csv"
	tmp_md := ".obench_test_report.md"
	tmp_spall := ".obench_test_trace.spall"
	defer {
		_ = os.remove(tmp_json)
		_ = os.remove(tmp_csv)
		_ = os.remove(tmp_md)
		_ = os.remove(tmp_spall)
	}

	cfg := quick_config()
	cfg.sample_count = 8
	cfg.baseline_save_path = tmp_json
	cfg.csv_export_path = tmp_csv
	cfg.md_export_path = tmp_md
	cfg.spall_export_path = tmp_spall

	s := obench.suite_create("unit_test_suite", cfg)
	defer obench.suite_destroy(&s)

	g := obench.group_add(&s, "ops")
	obench.group_bench(g, "fast_zero_alloc", _dummy_fast, zero_alloc = true)
	obench.group_bench(g, "heap_alloc_64b", _dummy_alloc)
	obench.group_bench(g, "batched_sort_16", _dummy_batched_sort, zero_alloc = true)
	obench.group_bench(g, "parallel_atomic_2t", _dummy_parallel, zero_alloc = true)
	obench.group_bench(g, `quote"and|pipe`, _noop_step)

	ok := obench.suite_run(&s)
	testing.expect(t, ok, "expected suite_run to pass zero_alloc checks")
	testing.expect_value(t, len(s.results), 5)
	testing.expect_value(t, s.results[0].stats.allocs_per_op, 0.0)
	testing.expect_value(t, s.results[0].stats.custom_metrics_count, 1)
	testing.expect_value(t, s.results[0].stats.custom_metrics[0].value, 99.5)
	testing.expect_value(t, s.results[1].stats.allocs_per_op, 1.0)
	testing.expect_value(t, s.results[1].stats.alloc_bytes_per_op, 64.0)
	testing.expect_value(t, s.results[2].stats.allocs_per_op, 0.0)
	testing.expect_value(t, s.results[3].stats.allocs_per_op, 0.0)
	testing.expect_value(t, intrinsics.atomic_load(&_parallel_counter), i64(16))
	testing.expect(t, s.summary.geomean_ns > 0.0, "expected positive suite geomean")

	// Baseline JSON reloads cleanly.
	loaded := make(map[string]obench.Stats)
	defer obench.destroy_baseline_map(&loaded, context.allocator)
	testing.expect_value(t, obench.load_baseline_file(tmp_json, &loaded, context.allocator), nil)
	testing.expect_value(t, len(loaded), 5)
	for name, st in loaded {
		testing.expectf(
			t,
			len(st.samples_ns) == st.samples,
			"%s: %v samples saved",
			name,
			len(st.samples_ns),
		)
	}

	// CSV and Markdown escape awkward names.
	csv_bytes, csv_err := os.read_entire_file(tmp_csv, context.temp_allocator)
	testing.expect_value(t, csv_err, nil)
	testing.expect(
		t,
		strings.contains(string(csv_bytes), `"ops::quote""and|pipe"`),
		"CSV doubles embedded quotes",
	)
	md_bytes, md_err := os.read_entire_file(tmp_md, context.temp_allocator)
	testing.expect_value(t, md_err, nil)
	testing.expect(
		t,
		strings.contains(string(md_bytes), `quote"and\|pipe`),
		"Markdown escapes pipes",
	)

	// Spall trace starts with the manual stream magic (0x0BADF00D).
	spall_bytes, spall_err := os.read_entire_file(tmp_spall, context.allocator)
	defer delete(spall_bytes)
	testing.expect_value(t, spall_err, nil)
	testing.expect(t, len(spall_bytes) >= 16, "expected non-empty Spall trace file")
	if len(spall_bytes) >= 8 {
		magic := (^u64le)(raw_data(spall_bytes))^
		testing.expect_value(t, magic, u64le(0x0BADF00D))
	}

	// benchstat-style comparison of a file against itself.
	cmp_passed, cmp_err := obench.compare_baseline_files(tmp_json, tmp_json, 2.0, false, true)
	testing.expect_value(t, cmp_err, nil)
	testing.expect(t, cmp_passed, "expected identical baselines to have 0 regressions")
}

@(test)
test_run_test_reports_through_the_test_runner :: proc(t: ^testing.T) {
	s := obench.suite_create("inside_odin_test", quick_config())
	defer obench.suite_destroy(&s)
	obench.bench(&s, "noop", _noop_step)
	obench.run_test(t, &s)
	testing.expect_value(t, len(s.results), 1)
	testing.expect_value(t, obench.suite_failure_count(&s), 0)
}

@(test)
test_missing_baseline_fails_the_run :: proc(t: ^testing.T) {
	cfg := quick_config()
	cfg.baseline_load_path = ".obench_test_does_not_exist.json"
	s := obench.suite_create("missing_baseline", cfg)
	defer obench.suite_destroy(&s)
	obench.bench(&s, "noop", _noop_step)
	testing.expect(t, !obench.suite_run(&s), "an unreadable baseline must not pass silently")
	testing.expect_value(t, s.failed_io, 1)
}

@(test)
test_merge_reports_and_filter_baseline_by_suite :: proc(t: ^testing.T) {
	paths := [?]string{".obench_test_merge_a.json", ".obench_test_merge_b.json"}
	merged_path := ".obench_test_merge_all.json"
	defer {
		for p in paths {
			_ = os.remove(p)
		}
		_ = os.remove(merged_path)
	}

	// Two suites that both contain a benchmark called "shared".
	for name, i in ([?]string{"suite_a", "suite_b"}) {
		cfg := quick_config()
		cfg.json_export_path = paths[i]
		s := obench.suite_create(name, cfg)
		obench.bench(&s, "shared", _noop_step)
		obench.bench(&s, fmt.tprintf("only_in_%s", name), _noop_step)
		testing.expect(t, obench.suite_run(&s))
		obench.suite_destroy(&s)
	}

	testing.expect_value(t, obench.merge_json_reports(paths[:], merged_path), nil)
	doc, read_err := obench.read_json_report(merged_path, context.temp_allocator)
	testing.expect_value(t, read_err, nil)
	testing.expect_value(t, len(doc.benchmarks), 4)
	testing.expect_value(t, doc.format_version, obench.REPORT_FORMAT_VERSION)
	testing.expect(t, doc.geomean_ns > 0 && !math.is_nan(doc.geomean_ns))

	loaded := make(map[string]obench.Stats)
	defer obench.destroy_baseline_map(&loaded, context.allocator)
	testing.expect_value(
		t,
		obench.load_baseline_file(merged_path, &loaded, context.allocator, "suite_b"),
		nil,
	)
	testing.expect_value(t, len(loaded), 2)
	testing.expect(t, "only_in_suite_b" in loaded)
	testing.expect(t, "only_in_suite_a" not_in loaded)
}

@(private = "file")
_heap_metric_unit :: proc(b: ^obench.Bencher) {
	unit := strings.clone("ops_heap")
	obench.report_metric(b, 7, unit)
	delete(unit) // The suite must have copied it already.
	long_unit := strings.repeat("é", 20, context.temp_allocator) // 40 bytes
	obench.report_metric(b, 8, long_unit)
	for obench.step(b) {
		_ = obench.black_box(1)
	}
}

@(test)
test_metric_unit_is_copied_when_reported :: proc(t: ^testing.T) {
	s := obench.suite_create("metric_copy", quick_config())
	defer obench.suite_destroy(&s)
	obench.bench(&s, "metric", _heap_metric_unit)

	testing.expect(t, obench.suite_run(&s))
	m := s.results[0].stats
	testing.expect_value(t, m.custom_metrics_count, 2)
	testing.expect_value(t, m.custom_metrics[0].unit, "ops_heap")
	testing.expect_value(t, m.custom_metrics[0].value, 7.0)
	// Cut at a UTF-8 boundary: 16 two-byte runes fit in MAX_METRIC_UNIT_LEN (32) bytes.
	testing.expect_value(t, len(m.custom_metrics[1].unit), 32)
	testing.expect_value(
		t,
		m.custom_metrics[1].unit,
		strings.repeat("é", 16, context.temp_allocator),
	)
}

@(private = "file")
_step_then_parallel :: proc(b: ^obench.Bencher) {
	for obench.step(b) {
		_ = obench.black_box(1)
	}
	obench.run_parallel(b, proc(pb: ^obench.Parallel_Bencher) {
			for obench.parallel_next(pb) {
				_ = obench.black_box(1)
			}
		}, num_threads = 2)
}

@(private = "file")
_batched_twice :: proc(b: ^obench.Bencher) {
	for _ in 0 ..< 2 {
		obench.iter_batched(b, setup = proc(b: ^obench.Bencher) -> int {
				return 1
			}, routine = proc(v: ^int) {
				_ = obench.black_box(v^)
			})
	}
}

@(test)
test_second_measurement_is_rejected :: proc(t: ^testing.T) {
	s := obench.suite_create("measured_twice", quick_config())
	defer obench.suite_destroy(&s)
	obench.bench(&s, "step_then_parallel", _step_then_parallel)
	obench.bench(&s, "batched_twice", _batched_twice)

	testing.expect(t, !obench.suite_run(&s))
	testing.expect_value(t, s.results[0].error, obench.Bench_Error.Measured_Twice)
	testing.expect_value(t, s.results[1].error, obench.Bench_Error.Measured_Twice)
	testing.expect_value(t, obench.bench_error_string(.Measured_Twice), "measured_twice")
}

@(private = "file")
_parallel_threads_seen: int

@(private = "file")
_parallel_default_threads :: proc(b: ^obench.Bencher) {
	obench.run_parallel(b, proc(pb: ^obench.Parallel_Bencher) {
		intrinsics.atomic_store_explicit(&_parallel_threads_seen, pb.num_threads, .Relaxed)
		for obench.parallel_next(pb) {
			_ = obench.black_box(1)
		}
	})
}

@(test)
test_run_parallel_defaults_to_four_threads :: proc(t: ^testing.T) {
	s := obench.suite_create("parallel_default", quick_config())
	defer obench.suite_destroy(&s)
	obench.bench(&s, "default_threads", _parallel_default_threads)

	testing.expect(t, obench.suite_run(&s))
	testing.expect_value(t, intrinsics.atomic_load(&_parallel_threads_seen), 4)
}

@(private = "file")
_allocs_then_expects_zero :: proc(b: ^obench.Bencher) {
	for obench.step(b) {
		buf := make([]u8, 24)
		obench.keep_alive(&buf)
		delete(buf)
	}
	obench.expect_zero_allocs(b) // Called after the loop, on purpose.
}

@(test)
test_late_expect_zero_allocs_reports_the_location :: proc(t: ^testing.T) {
	s := obench.suite_create("late_expect_zero", quick_config())
	defer obench.suite_destroy(&s)
	obench.bench(&s, "late", _allocs_then_expects_zero)

	testing.expect(t, !obench.suite_run(&s))
	r := &s.results[0]
	testing.expect(t, r.zero_alloc_failed)
	testing.expect_value(t, r.violation_size, 24)
	testing.expect(t, r.violation_loc.line > 0, "the first allocation's location must be recorded")
}

@(private = "file")
_kept_buffers: [dynamic][]u8

@(private = "file")
_keeps_until_next_sample :: proc(b: ^obench.Bencher) {
	// Runs before the loop, outside the measurement.
	for buf in _kept_buffers {
		delete(buf)
	}
	clear(&_kept_buffers)
	for obench.step(b) {
		append(&_kept_buffers, make([]u8, 100))
	}
}

@(test)
test_peak_heap_bytes_is_per_sample :: proc(t: ^testing.T) {
	_kept_buffers = make([dynamic][]u8, 0, 64)
	defer {
		for buf in _kept_buffers {
			delete(buf)
		}
		delete(_kept_buffers)
	}

	s := obench.suite_create("peak_per_sample", quick_config()) // 16 iterations per sample
	defer obench.suite_destroy(&s)
	obench.bench(&s, "keeps", _keeps_until_next_sample)

	testing.expect(t, obench.suite_run(&s))
	testing.expect_value(t, s.results[0].stats.peak_heap_bytes, i64(16 * 100))
}

@(private = "file")
_spins_param :: proc(b: ^obench.Bencher) {
	for obench.step(b) {
		acc := 0
		for i in 0 ..< b.param {
			acc += obench.black_box(i)
		}
		_ = obench.black_box(acc)
	}
}

@(test)
test_thread_speedups_compare_the_same_param :: proc(t: ^testing.T) {
	s := obench.suite_create("speedup_per_param", quick_config())
	defer obench.suite_destroy(&s)
	g := obench.group_add(&s, "scale")
	obench.group_params(g, []int{1, 2000})
	obench.group_threads(g, []int{1, 2})
	obench.group_bench(g, "spin", _spins_param)

	testing.expect(t, obench.suite_run(&s))
	testing.expect_value(t, len(s.results), 4)
	// Results run params × threads: [1]/t1, [1]/t2, [2000]/t1, [2000]/t2.
	testing.expect_value(t, s.results[2].full_name, "scale::spin[2000]/t1")
	testing.expect_value(t, s.results[2].speedup_vs_first, 1.0)
}

@(private = "file")
_spin_for :: proc(d: time.Duration) {
	start := time.tick_now()
	for time.tick_since(start) < d {
		intrinsics.cpu_relax()
	}
}

@(private = "file")
_heavy_setup :: proc(b: ^obench.Bencher) {
	obench.iter_batched(b, setup = proc(b: ^obench.Bencher) -> int {
			_spin_for(100 * time.Microsecond)
			return 1
		}, routine = proc(v: ^int) {
			_ = obench.black_box(v^)
		})
}

@(test)
test_calibration_is_bounded_by_wall_time :: proc(t: ^testing.T) {
	cfg := quick_config()
	cfg.fixed_batch_size = 0 // Calibrate.
	s := obench.suite_create("heavy_setup", cfg)
	defer obench.suite_destroy(&s)
	obench.bench(&s, "heavy_setup", _heavy_setup)

	start := time.tick_now()
	testing.expect(t, obench.suite_run(&s))
	elapsed := time.tick_since(start)
	// Unbounded, calibration grows the batch until the ~1 ns routine fills 50 us of timed
	// work, which takes seconds of 100 us setups.
	testing.expectf(t, elapsed < 1500 * time.Millisecond, "calibration took %v", elapsed)
}

@(test)
test_unmatched_filter_keeps_existing_reports :: proc(t: ^testing.T) {
	path := ".obench_test_filter_keep.json"
	defer _ = os.remove(path)

	cfg := quick_config()
	cfg.baseline_save_path = path
	{
		s := obench.suite_create("filter_keep", cfg)
		defer obench.suite_destroy(&s)
		obench.bench(&s, "noop", _noop_step)
		testing.expect(t, obench.suite_run(&s))
	}
	before, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, err, nil)

	cfg.filter = "no_such_benchmark"
	s := obench.suite_create("filter_keep", cfg)
	defer obench.suite_destroy(&s)
	obench.bench(&s, "noop", _noop_step)
	testing.expect(t, obench.suite_run(&s))
	testing.expect_value(t, len(s.results), 0)

	after, after_err := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, after_err, nil)
	testing.expect(t, string(before) == string(after), "the saved baseline must not be replaced")
}

@(test)
test_comparison_counts_benchmarks_that_started_failing :: proc(t: ^testing.T) {
	base_entries := []obench.Export_Entry {
		{suite_name = "s", full_name = "ok", samples = 10, p50_ns = 10, mean_ns = 10},
		{suite_name = "s", full_name = "breaks", samples = 10, p50_ns = 10, mean_ns = 10},
	}
	cand_entries := []obench.Export_Entry {
		{suite_name = "s", full_name = "ok", samples = 10, p50_ns = 10, mean_ns = 10},
		{suite_name = "s", full_name = "breaks", error = "no_measurement"},
	}
	baseline := obench.Export_Document {
		benchmarks = base_entries,
	}
	candidate := obench.Export_Document {
		benchmarks = cand_entries,
	}

	sb := strings.builder_make(context.temp_allocator)
	summary := obench.write_comparison(strings.to_writer(&sb), baseline, candidate, 2.0, false)
	testing.expect_value(t, summary.matched, 1)
	testing.expect_value(t, summary.errored, 1)
	testing.expect_value(t, summary.only_in_baseline, 0)
	testing.expect(t, strings.contains(strings.to_string(sb), "no_measurement"))
}

@(test)
test_csv_keeps_precision_and_leaves_unset_columns_empty :: proc(t: ^testing.T) {
	path := ".obench_test_precision.csv"
	defer _ = os.remove(path)

	cfg := quick_config()
	cfg.csv_export_path = path
	s := obench.suite_create("csv_precision", cfg)
	defer obench.suite_destroy(&s)
	obench.bench(&s, "noop", _noop_step)
	testing.expect(t, obench.suite_run(&s))

	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, err, nil)
	lines := strings.split_lines(string(data), context.temp_allocator)
	testing.expect(t, len(lines) >= 2)
	fields := strings.split(strings.trim_right(lines[1], "\r"), ",", context.temp_allocator)
	testing.expect_value(t, fields[4], "") // param
	testing.expect_value(t, fields[5], "") // threads
	// p50 written without a fixed number of decimals: it parses back to the same value.
	p50, ok := strconv.parse_f64(fields[10])
	testing.expect(t, ok)
	testing.expect_value(t, p50, s.results[0].stats.p50_ns)
}
