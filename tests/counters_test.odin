package obench_tests

import obench "../obench"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_counter_group_counts_software_events_where_allowed :: proc(t: ^testing.T) {
	g, ok, why := obench.counter_group_open(.Software)
	defer obench.counter_group_close(&g)
	when ODIN_OS != .Linux {
		testing.expect(t, !ok && why != "", "counters need Linux")
		return
	}
	if !ok {
		// perf_event_paranoid or a seccomp filter can refuse even software events.
		testing.expect(t, why != "")
		return
	}
	before, read_before := obench.counter_group_read(&g)
	busy := 0
	for i in 0 ..< 20_000_000 {
		busy += obench.black_box(i)
	}
	after, read_after := obench.counter_group_read(&g)
	testing.expect(t, read_before && read_after)
	// The first slot of a software group is the task clock, in nanoseconds.
	testing.expectf(
		t,
		after.instructions > before.instructions,
		"task clock %v -> %v (%d)",
		before.instructions,
		after.instructions,
		busy,
	)
}

@(private = "file")
_counted_step :: proc(b: ^obench.Bencher) {
	for obench.step(b) {
		_ = obench.black_box(1)
	}
}

@(test)
test_counters_show_up_or_say_why_not :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cfg := obench.Config {
		warmup_time         = 1 * time.Millisecond,
		min_sample_time     = 50 * time.Microsecond,
		max_bench_time      = 50 * time.Millisecond,
		sample_count        = 5,
		untimed_alloc_check = obench.DEFAULT_UNTIMED_ALLOCS,
		noise_threshold_pct = 2.0,
		counters            = true,
	}
	s := obench.suite_create("counters", cfg)
	defer obench.suite_destroy(&s)
	obench.bench(&s, "loop", _counted_step)
	testing.expect(t, obench.suite_run(&s), "missing counters never fail a run")
	sb := strings.builder_make(context.temp_allocator)
	obench.write_terminal_report(strings.to_writer(&sb), &s)
	report := strings.to_string(sb)
	if s.counters_unavailable != "" {
		testing.expect(t, !s.results[0].stats.has_counters)
		testing.expect(
			t,
			strings.contains(report, "note: --counters: no hardware counters here"),
			report,
		)
	} else {
		testing.expect(t, s.results[0].stats.has_counters)
		testing.expect(t, s.results[0].stats.counters.instructions > 0)
		testing.expect(t, strings.contains(report, "instructions"), report)
	}

	// The columns, with counters made up for the table.
	s.results[0].stats.has_counters = true
	s.results[0].stats.counters = {
		instructions  = 2500,
		cycles        = 1000,
		branch_misses = 3,
		cache_misses  = 0.5,
	}
	strings.builder_reset(&sb)
	obench.write_terminal_report(strings.to_writer(&sb), &s)
	report = strings.to_string(sb)
	for want in ([]string{"instructions", "IPC", "branch misses", "cache misses", "2.50k", "2.50", "3.0", "0.5"}) {
		testing.expectf(t, strings.contains(report, want), "missing %q in %s", want, report)
	}
	doc := obench.export_document(&s, context.temp_allocator)
	testing.expect_value(t, doc.benchmarks[0].instructions, 2500.0)
}
