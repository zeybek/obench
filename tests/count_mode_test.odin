package obench_tests

import obench "../obench"
import "core:testing"

@(private = "file")
_iterations: int

@(private = "file")
_counting_step :: proc(b: ^obench.Bencher) {
	for obench.step(b) {
		_iterations += 1
	}
}

@(test)
test_count_mode_runs_one_iteration_then_the_count_and_nothing_else :: proc(t: ^testing.T) {
	cfg := obench.Config {
		count_iterations    = 37,
		exact               = "counted",
		untimed_alloc_check = obench.DEFAULT_UNTIMED_ALLOCS,
	}
	s := obench.suite_create("count_mode", cfg)
	defer obench.suite_destroy(&s)
	obench.bench(&s, "counted", _counting_step)
	obench.bench(&s, "not_selected", _counting_step)
	testing.expect_value(t, s.clock.overhead_ns, 0)
	testing.expect(t, obench.suite_run(&s))
	testing.expect_value(t, _iterations, 1 + 37)
	testing.expect_value(t, len(s.results), 0)
	testing.expect_value(t, s.empty_loop_ns, 0)
}

@(test)
test_benchmark_selected :: proc(t: ^testing.T) {
	testing.expect(
		t,
		obench.benchmark_selected({filter = `sort\[(32|512)\]`}, "in_place_sort::slice_sort[512]"),
	)
	testing.expect(
		t,
		!obench.benchmark_selected(
			{filter = `sort\[(32|512)\]`},
			"in_place_sort::slice_sort[128]",
		),
	)
	testing.expect(
		t,
		!obench.benchmark_selected({skip = "insertion"}, "in_place_sort::insertion_sort[32]"),
	)
	testing.expect(t, obench.benchmark_selected({exact = "a::b"}, "a::b"))
	testing.expect(t, !obench.benchmark_selected({exact = "a::b"}, "a::bc"))
	testing.expect(t, obench.benchmark_selected({}, "anything"))
}
