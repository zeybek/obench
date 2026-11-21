package obench_tests

import obench "../obench"
import "core:math"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_machine_notes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	unfit := obench.Machine_State {
		governor   = "powersave",
		boost      = "on",
		load_avg   = 5,
		on_battery = true,
		vm         = true,
	}
	notes := obench.machine_notes(unfit, 8)
	warnings := 0
	for n in notes {
		warnings += int(n.warning)
	}
	testing.expect_value(t, len(notes), 5)
	testing.expect_value(t, warnings, 3)
	testing.expect(t, strings.contains(notes[0].text, "'powersave'"), notes[0].text)

	fit := obench.Machine_State {
		governor = "performance",
		boost    = "off",
		load_avg = 0.5,
	}
	testing.expect_value(t, len(obench.machine_notes(fit, 8)), 0)
	// One busy core on a two-core machine is half of it.
	testing.expect_value(t, len(obench.machine_notes({load_avg = 1}, 2)), 1)
}

@(test)
test_read_machine_state_and_pin_thread :: proc(t: ^testing.T) {
	st := obench.read_machine_state()
	defer obench.machine_state_destroy(&st)
	testing.expect(t, st.load_avg >= 0)

	_, ok, why := obench.pin_thread(-1)
	testing.expect(t, !ok && why != "")
	previous, pinned, reason := obench.pin_thread(0)
	defer obench.unpin_thread(previous)
	when ODIN_OS == .Linux || ODIN_OS == .Windows {
		testing.expectf(t, pinned, "pinning to CPU 0 failed: %s", reason)
	} else {
		testing.expect(t, !pinned && reason != "", "only Linux and Windows can pin")
	}
}

@(private = "file")
_machine_step :: proc(b: ^obench.Bencher) {
	for obench.step(b) {
		_ = obench.black_box(1)
	}
}

@(test)
test_empty_loop_and_the_notes_it_drives :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cfg := obench.Config {
		warmup_time         = 1 * time.Millisecond,
		min_sample_time     = 50 * time.Microsecond,
		max_bench_time      = 50 * time.Millisecond,
		sample_count        = 10,
		untimed_alloc_check = obench.DEFAULT_UNTIMED_ALLOCS,
		noise_threshold_pct = 2.0,
	}
	s := obench.suite_create("empty_loop", cfg)
	defer obench.suite_destroy(&s)
	obench.bench(&s, "work", _machine_step)
	testing.expect(t, obench.suite_run(&s))
	testing.expect(t, s.empty_loop_ns > 0, "the empty loop is timed after the benchmarks")
	doc := obench.export_document(&s, context.temp_allocator)
	testing.expect_value(t, doc.clock.empty_loop_ns, s.empty_loop_ns)
	testing.expect_value(t, doc.benchmarks[0].modes, s.results[0].stats.modes)

	s.results[0].stats.trend_pct = 7
	s.results[0].stats.modes = 2
	s.empty_loop_ns = s.results[0].stats.p50_ns * 10
	sb := strings.builder_make(context.temp_allocator)
	obench.write_terminal_report(strings.to_writer(&sb), &s)
	report := strings.to_string(sb)
	testing.expect(t, strings.contains(report, ", empty loop "), report)
	testing.expect(t, strings.contains(report, "[near empty loop]"), report)
	testing.expect(t, strings.contains(report, "[drifts +7%]"), report)
	testing.expect(t, strings.contains(report, "[2 modes]"), report)
}

// `fixed_batch_size` is for the benchmarks. With a batch of 1 the empty loop would be a
// single iteration per sample, far below what the clock can resolve. Timing it shows which
// batch it got: the benchmark's 5 samples of one iteration take microseconds, and 5 calibrated
// samples of the empty loop take 10 ms each.
@(test)
test_empty_loop_is_calibrated_whatever_the_batch_size :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cfg := obench.Config {
		warmup_time         = 0,
		min_sample_time     = 10 * time.Millisecond,
		max_bench_time      = 50 * time.Millisecond,
		sample_count        = 5,
		fixed_batch_size    = 1,
		untimed_alloc_check = obench.DEFAULT_UNTIMED_ALLOCS,
		noise_threshold_pct = 2.0,
	}
	s := obench.suite_create("empty_loop_batch", cfg)
	defer obench.suite_destroy(&s)
	obench.bench(&s, "work", _machine_step)
	start := time.tick_now()
	testing.expect(t, obench.suite_execute(&s))
	took := time.tick_since(start)
	testing.expect_value(t, s.results[0].stats.batch_size, 1)
	testing.expect(t, s.empty_loop_ns > 0, "the empty loop is timed")
	testing.expectf(
		t,
		took >= 25 * time.Millisecond,
		"the suite took %v, so the empty loop ran with the benchmarks' batch of 1",
		took,
	)
}

@(test)
test_ci95_counts_the_samples_correlated_samples_are_worth :: proc(t: ^testing.T) {
	values := make([]f64, 50, context.temp_allocator)
	defer free_all(context.temp_allocator)
	for &v, i in values {
		v = 100 + math.sin(f64(i) / 5)
	}
	st := obench.compute_stats(values, values, 1, u64(len(values)), 0, 0, nil, nil)
	testing.expect(t, st.autocorrelation > 0.9)
	testing.expect_value(t, st.effective_samples, 2.0)
	naive := obench.t_critical_975(49) * st.std_dev_ns / math.sqrt(f64(50))
	testing.expectf(
		t,
		st.ci95_ns > 10 * naive,
		"ci95 %v should be far wider than %v",
		st.ci95_ns,
		naive,
	)
}
