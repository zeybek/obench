package obench_tests

import obench "../obench"
import "core:testing"
import "core:time"

@(private = "file")
_calls: int

// Stalls once, in the first calibration probe: with no warmup time, the warmup runs one
// batch and calibration starts with the second call.
@(private = "file")
_stall_in_first_probe :: proc(b: ^obench.Bencher) {
	_calls += 1
	stall := _calls == 2
	for obench.step(b) {
		if stall {
			time.sleep(2 * time.Millisecond)
			stall = false
		}
		_ = obench.black_box(1)
	}
}

@(test)
test_one_stalled_probe_does_not_decide_the_batch_size :: proc(t: ^testing.T) {
	cfg := obench.Config {
		warmup_time         = 0,
		min_sample_time     = 50 * time.Microsecond,
		// The stalled probe is only repeated while it fits the budget twice over, and on a busy
		// runner the 2 ms sleep can last far longer.
		max_bench_time      = 2 * time.Second,
		sample_count        = 5,
		untimed_alloc_check = obench.DEFAULT_UNTIMED_ALLOCS,
		noise_threshold_pct = 2.0,
	}
	s := obench.suite_create("stalled_probe", cfg)
	defer obench.suite_destroy(&s)
	obench.bench(&s, "noop", _stall_in_first_probe)
	testing.expect(t, obench.suite_run(&s))
	if !testing.expect_value(t, len(s.results), 1) {
		return
	}
	testing.expect(t, _calls > 2, "the stalled probe ran")
	testing.expectf(
		t,
		s.results[0].stats.batch_size >= 100,
		"batch size %d: one stalled probe ended the calibration",
		s.results[0].stats.batch_size,
	)
}
