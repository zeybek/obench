package obench_tests

import obench "../obench"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// The same small configuration as `quick_config` in obench_test.odin.
@(private = "file")
_failure_config :: proc() -> obench.Config {
	return obench.Config {
		warmup_time = 1 * time.Millisecond,
		min_sample_time = 50 * time.Microsecond,
		max_bench_time = 50 * time.Millisecond,
		sample_count = 10,
		fixed_batch_size = 16,
		reset_temp_per_iter = true,
		untimed_alloc_check = obench.DEFAULT_UNTIMED_ALLOCS,
		noise_threshold_pct = 2.0,
	}
}

@(private = "file")
_never_measures :: proc(b: ^obench.Bencher) {
}

@(private = "file")
_allocates_each_iteration :: proc(b: ^obench.Bencher) {
	for obench.step(b) {
		buf := make([]u8, 24)
		obench.keep_alive(&buf)
		delete(buf)
	}
}

@(private = "file")
_does_nothing :: proc(b: ^obench.Bencher) {
	for obench.step(b) {
		_ = obench.black_box(1)
	}
}

@(private = "file")
_message_about :: proc(messages: []string, name, text: string) -> bool {
	for m in messages {
		if strings.has_prefix(m, name) && strings.contains(m, text) {
			return true
		}
	}
	return false
}

@(test)
test_suite_failure_messages_name_each_benchmark_and_why :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	s := obench.suite_create("failures", _failure_config())
	defer obench.suite_destroy(&s)
	obench.bench(&s, "never_measures", _never_measures)
	obench.bench(&s, "allocates", _allocates_each_iteration, zero_alloc = true)
	obench.bench(&s, "fine", _does_nothing, zero_alloc = true)
	testing.expect(t, !obench.suite_run(&s))

	messages := obench.suite_failure_messages(&s)
	testing.expect_value(t, len(messages), 2)
	testing.expect(
		t,
		_message_about(messages, "never_measures: ", "never called obench.step"),
		strings.join(messages, "\n", context.temp_allocator),
	)
	testing.expect(
		t,
		_message_about(messages, "allocates: ", "in a @zero_alloc benchmark"),
		strings.join(messages, "\n", context.temp_allocator),
	)
}

@(test)
test_suite_failure_messages_cover_the_allocation_gate :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := ".obench_test_failure_messages.json"
	defer _ = os.remove(path)

	cfg := _failure_config()
	cfg.baseline_save_path = path
	{
		s := obench.suite_create("alloc_messages", cfg)
		defer obench.suite_destroy(&s)
		obench.bench(&s, "work", _does_nothing)
		testing.expect(t, obench.suite_run(&s))
		testing.expect_value(t, len(obench.suite_failure_messages(&s)), 0)
	}

	cfg.baseline_save_path = ""
	cfg.baseline_load_path = path
	cfg.fail_on_alloc_regression = true
	s := obench.suite_create("alloc_messages", cfg)
	defer obench.suite_destroy(&s)
	obench.bench(&s, "work", _allocates_each_iteration)
	testing.expect(t, !obench.suite_run(&s))
	messages := obench.suite_failure_messages(&s)
	testing.expect_value(t, len(messages), 1)
	testing.expect(
		t,
		_message_about(messages, "work: ", "allocates more per operation than in the baseline"),
		strings.join(messages, "\n", context.temp_allocator),
	)
}
