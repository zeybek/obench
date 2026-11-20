package obench_tests

import obench "../obench"
import "core:testing"

@(private = "file")
_run_doc :: proc(p50: f64, samples: []f64, err := "") -> obench.Export_Document {
	entries := make([]obench.Export_Entry, 1, context.temp_allocator)
	entries[0] = obench.Export_Entry {
		suite_name = "s",
		full_name  = "work",
		samples    = len(samples),
		batch_size = 1,
		p50_ns     = p50,
		samples_ns = samples,
		error      = err,
	}
	return obench.Export_Document {
		format_version = obench.REPORT_FORMAT_VERSION,
		benchmarks = entries,
	}
}

@(test)
test_combine_runs_pools_samples_and_keeps_process_medians :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	docs := []obench.Export_Document {
		_run_doc(10, {9, 10, 11}),
		_run_doc(12, {11, 12, 13}),
		_run_doc(11, {10, 11, 12}),
	}
	combined := obench.combine_runs(docs, context.temp_allocator)
	testing.expect_value(t, combined.processes, 3)
	e := combined.benchmarks[0]
	testing.expect_value(t, len(e.process_medians_ns), 3)
	testing.expect_value(t, e.process_medians_ns[1], 12.0)
	testing.expect_value(t, e.samples, 9)
	testing.expect_value(t, e.p50_ns, 11.0)
	testing.expect_value(t, e.min_ns, 9.0)
	testing.expect_value(t, e.max_ns, 13.0)
	testing.expect(t, abs(combined.geomean_ns - 11) < 1e-9)

	failed := []obench.Export_Document {
		_run_doc(10, {9, 10, 11}),
		_run_doc(0, nil, "Loop_Exited_Early"),
	}
	testing.expect_value(
		t,
		obench.combine_runs(failed, context.temp_allocator).benchmarks[0].error,
		"Loop_Exited_Early",
	)
}

@(test)
test_compare_baseline_uses_process_medians_when_both_sides_have_them :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	samples := []f64{100, 101, 102, 103, 104, 105, 106, 107, 108, 109}
	slow := []f64{120, 121, 122, 123, 124}
	same := []f64{100, 101, 102, 103, 104}
	cur := obench.Stats {
		samples            = len(samples),
		p50_ns             = 104.5,
		mean_ns            = 104.5,
		samples_ns         = samples,
		process_medians_ns = slow,
	}
	base := cur
	base.process_medians_ns = same
	// The pooled samples are identical; only the processes say it got slower.
	testing.expect(t, obench.compare_baseline(cur, base, 2.0).is_regression)
	cur.process_medians_ns = nil
	testing.expect(
		t,
		!obench.compare_baseline(cur, base, 2.0).is_regression,
		"one side has no processes",
	)
}

@(test)
test_combine_runs_carries_the_processes_of_combined_reports :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	first := obench.combine_runs(
		[]obench.Export_Document{_run_doc(10, {9, 10, 11}), _run_doc(12, {11, 12, 13})},
		context.temp_allocator,
	)
	again := obench.combine_runs(
		[]obench.Export_Document{first, _run_doc(11, {10, 11, 12})},
		context.temp_allocator,
	)
	testing.expect_value(t, again.processes, 3)
	medians := again.benchmarks[0].process_medians_ns
	testing.expect_value(t, len(medians), 3)
	testing.expect_value(t, medians[0], 10.0)
	testing.expect_value(t, medians[1], 12.0)
	testing.expect_value(t, medians[2], 11.0)
}
