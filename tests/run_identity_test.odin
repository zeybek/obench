package obench_tests

import obench "../obench"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
_identity_config :: proc() -> obench.Config {
	return obench.Config {
		warmup_time = 1 * time.Millisecond,
		min_sample_time = 50 * time.Microsecond,
		max_bench_time = 50 * time.Millisecond,
		sample_count = 10,
		fixed_batch_size = 16,
		reset_temp_per_iter = true,
		untimed_alloc_check = obench.DEFAULT_UNTIMED_ALLOCS,
		noise_threshold_pct = 2.0,
		machine_label = "test-machine",
	}
}

@(private = "file")
_with_metric :: proc(b: ^obench.Bencher) {
	obench.report_metric(b, 99.5, "hit%", .Higher_Is_Better)
	for obench.step(b) {
		_ = obench.black_box(1)
	}
}

@(test)
test_reports_record_the_run_machine_build_and_clock :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cfg := _identity_config()
	s := obench.suite_create("identity", cfg)
	defer obench.suite_destroy(&s)
	obench.bench(&s, "metric", _with_metric, zero_alloc = true)
	testing.expect(t, obench.suite_run(&s))

	doc := obench.export_document(&s, context.temp_allocator)
	testing.expect_value(t, doc.format_version, 6)
	_, consumed := time.rfc3339_to_time_utc(doc.created_at)
	testing.expectf(t, consumed > 0, "created_at %q should be RFC 3339", doc.created_at)
	testing.expect_value(t, doc.machine.label, "test-machine")
	testing.expect(t, doc.machine.cores > 0)
	testing.expect_value(t, doc.build.odin_version_hash, ODIN_VERSION_HASH)
	testing.expect_value(t, doc.build.microarch, ODIN_MICROARCH_STRING)
	testing.expect_value(t, doc.build.bounds_checks, "off" when ODIN_NO_BOUNDS_CHECK else "on")
	testing.expect_value(t, doc.config.samples, cfg.sample_count)
	testing.expect_value(t, doc.config.fixed_batch_size, cfg.fixed_batch_size)
	testing.expect_value(t, doc.clock.overhead_ns, s.clock.overhead_ns)
	testing.expect_value(t, doc.clock.resolution_ns, s.clock.resolution_ns)
	if testing.expect_value(t, len(doc.benchmarks), 1) {
		e := doc.benchmarks[0]
		testing.expect(t, e.zero_alloc, "the benchmark was @zero_alloc")
		testing.expect(t, !e.zero_alloc_failed)
		testing.expect_value(t, e.windows_per_sample, 1.0)
	}
}

@(test)
test_run_identity_and_metric_direction_survive_a_json_round_trip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := ".obench_test_run_identity.json"
	defer _ = os.remove(path)
	cfg := _identity_config()
	cfg.json_export_path = path
	s := obench.suite_create("identity_json", cfg)
	defer obench.suite_destroy(&s)
	obench.bench(&s, "metric", _with_metric)
	testing.expect(t, obench.suite_run(&s))

	doc, err := obench.read_json_report(path, context.temp_allocator)
	if !testing.expect_value(t, err, nil) {
		return
	}
	testing.expect_value(t, doc.format_version, obench.REPORT_FORMAT_VERSION)
	testing.expect_value(t, doc.machine.label, "test-machine")
	testing.expect_value(t, doc.build.odin_version_hash, ODIN_VERSION_HASH)
	testing.expect_value(t, doc.config.samples, cfg.sample_count)
	testing.expect_value(t, doc.clock.resolution_ns, s.clock.resolution_ns)
	if testing.expect_value(t, len(doc.benchmarks), 1) &&
	   testing.expect_value(t, len(doc.benchmarks[0].custom_metrics), 1) {
		m := doc.benchmarks[0].custom_metrics[0]
		testing.expect_value(t, m.unit, "hit%")
		testing.expect_value(t, m.better, obench.Metric_Better.Higher_Is_Better)
	}
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect(
		t,
		strings.contains(string(data), `"better": "Higher_Is_Better"`),
		"the direction is written by name",
	)
}

@(test)
test_a_baseline_built_with_another_microarch_is_not_comparable :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	entry := obench.Export_Entry {
		suite_name = "s",
		full_name  = "work",
		samples    = 10,
		p50_ns     = 100,
		mean_ns    = 100,
		std_dev_ns = 1,
	}
	base := obench.Export_Document {
		format_version = obench.REPORT_FORMAT_VERSION,
		optimization = "Speed",
		os = "linux",
		arch = "amd64",
		build = {microarch = "generic", bounds_checks = "on"},
		benchmarks = []obench.Export_Entry{entry},
	}
	sb := strings.builder_make(context.temp_allocator)
	w := strings.to_writer(&sb)

	native := base
	native.build.microarch = "native"
	testing.expect(t, obench.write_comparison(w, base, native, 2.0, false).build_mismatch)

	unchecked := base
	unchecked.build.bounds_checks = "off"
	testing.expect(t, obench.write_comparison(w, base, unchecked, 2.0, false).build_mismatch)
	testing.expect(t, strings.contains(strings.to_string(sb), "-no-bounds-check"))

	// A report older than format version 6 has no build settings, which isn't held against it.
	older := base
	older.build = {}
	testing.expect(t, !obench.write_comparison(w, older, native, 2.0, false).build_mismatch)
}
