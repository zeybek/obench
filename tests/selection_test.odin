package obench_tests

import obench "../obench"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
_select_config :: proc() -> obench.Config {
	return obench.Config {
		warmup_time = 1 * time.Millisecond,
		min_sample_time = 50 * time.Microsecond,
		max_bench_time = 50 * time.Millisecond,
		sample_count = 5,
		fixed_batch_size = 16,
		untimed_alloc_check = obench.DEFAULT_UNTIMED_ALLOCS,
		noise_threshold_pct = 2.0,
	}
}

@(private = "file")
_select_step :: proc(b: ^obench.Bencher) {
	for obench.step(b) {
		_ = obench.black_box(1)
	}
}

// The names of the benchmarks a selection runs, out of lookup::{linear_scan, odin_map}[8, 64].
@(private = "file")
_selected_names :: proc(filter, skip, exact: string) -> []string {
	cfg := _select_config()
	cfg.filter = filter
	cfg.skip = skip
	cfg.exact = exact
	s := obench.suite_create("selection", cfg)
	defer obench.suite_destroy(&s)
	g := obench.group_add(&s, "lookup")
	obench.group_params(g, {8, 64})
	obench.group_bench(g, "linear_scan", _select_step)
	obench.group_bench(g, "odin_map", _select_step)
	_ = obench.suite_run(&s)
	names := make([]string, len(s.results), context.temp_allocator)
	for r, i in s.results {
		names[i] = strings.clone(r.full_name, context.temp_allocator)
	}
	return names
}

@(private = "file")
_expect_names :: proc(t: ^testing.T, got: []string, want: []string, loc := #caller_location) {
	if !testing.expectf(t, len(got) == len(want), "got %v, want %v", got, want, loc = loc) {
		return
	}
	for name, i in want {
		testing.expectf(t, got[i] == name, "got %v, want %v", got, want, loc = loc)
	}
}

@(test)
test_filter_skip_and_exact_select_benchmarks :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	_expect_names(
		t,
		_selected_names(`odin_map\[(8|64)\]`, "", ""),
		{"lookup::odin_map[8]", "lookup::odin_map[64]"},
	)
	// A plain substring with brackets still selects what it did before filters were regexes.
	_expect_names(t, _selected_names("odin_map[64]", "", ""), {"lookup::odin_map[64]"})
	// Not a regular expression: it only matches as text.
	_expect_names(
		t,
		_selected_names("odin_map[", "", ""),
		{"lookup::odin_map[8]", "lookup::odin_map[64]"},
	)
	_expect_names(
		t,
		_selected_names("", "linear", ""),
		{"lookup::odin_map[8]", "lookup::odin_map[64]"},
	)
	_expect_names(
		t,
		_selected_names("lookup", `\[8\]`, ""),
		{"lookup::linear_scan[64]", "lookup::odin_map[64]"},
	)
	_expect_names(t, _selected_names("", "", "lookup::odin_map[64]"), {"lookup::odin_map[64]"})
	_expect_names(t, _selected_names("", "", "lookup::odin_map"), {})
}

@(test)
test_parse_duration :: proc(t: ^testing.T) {
	cases := []struct {
		text: string,
		want: time.Duration,
	} {
		{"200ms", 200 * time.Millisecond},
		{"500us", 500 * time.Microsecond},
		{"3µs", 3 * time.Microsecond},
		{"1.5s", 1500 * time.Millisecond},
		{"250ns", 250},
	}
	for c in cases {
		d, ok := obench.parse_duration(c.text)
		testing.expectf(t, ok && d == c.want, "%q: got %v (%v), want %v", c.text, d, ok, c.want)
	}
	for bad in ([]string{"200", "ms", "-1ms", "1h", ""}) {
		_, ok := obench.parse_duration(bad)
		testing.expectf(t, !ok, "%q should not parse", bad)
	}
}

@(test)
test_test_mode_runs_each_benchmark_once_and_saves_no_baseline :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := ".obench_test_mode_baseline.json"
	defer _ = os.remove(path)
	cfg := _select_config()
	cfg.fixed_batch_size = 0
	cfg.test_mode = true
	cfg.baseline_save_path = path
	s := obench.suite_create("test_mode", cfg)
	defer obench.suite_destroy(&s)
	obench.bench(&s, "a", _select_step)
	obench.bench(&s, "b", _select_step)
	testing.expect(t, obench.suite_run(&s))
	testing.expect_value(t, len(s.results), 2)
	for r in s.results {
		testing.expect_value(t, r.stats.samples, 1)
		testing.expect_value(t, r.stats.batch_size, 1)
	}
	testing.expect(t, !os.exists(path), "--test must not save a baseline")
}

@(test)
test_quiet_prints_only_the_summary :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	cfg := _select_config()
	cfg.quiet = true
	s := obench.suite_create("quiet", cfg)
	defer obench.suite_destroy(&s)
	obench.bench(&s, "a", _select_step)
	testing.expect(t, obench.suite_run(&s))
	sb := strings.builder_make(context.temp_allocator)
	obench.write_terminal_report(strings.to_writer(&sb), &s)
	out := strings.to_string(sb)
	testing.expect(t, strings.has_prefix(out, "PASS: 1 benchmark(s) completed"), out)
	testing.expect_value(t, strings.count(out, "\n"), 2)
}
