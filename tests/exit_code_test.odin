package obench_tests

import obench "../obench"
import "core:os"
import "core:testing"
import "core:time"

@(private = "file")
_exit_config :: proc() -> obench.Config {
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
_exit_step :: proc(b: ^obench.Bencher) {
	for obench.step(b) {
		_ = obench.black_box(1)
	}
}

@(test)
test_suite_exit_code_puts_failures_before_the_baseline :: proc(t: ^testing.T) {
	s: obench.Suite
	testing.expect_value(t, obench.suite_exit_code(&s), obench.EXIT_SUCCESS)
	s.failed_regressions = 1
	testing.expect_value(t, obench.suite_exit_code(&s), obench.EXIT_FAILURE)
	// A regression against a baseline that can't be compared means nothing.
	s.failed_baseline = 1
	testing.expect_value(t, obench.suite_exit_code(&s), obench.EXIT_BASELINE)
	// A benchmark that failed, or allocates more, did so whatever the baseline.
	s.failed_alloc_regressions = 1
	testing.expect_value(t, obench.suite_exit_code(&s), obench.EXIT_FAILURE)
	s.failed_alloc_regressions = 0
	s.failed_errors = 1
	testing.expect_value(t, obench.suite_exit_code(&s), obench.EXIT_FAILURE)
}

@(test)
test_a_baseline_without_the_suites_benchmarks_exits_with_3 :: proc(t: ^testing.T) {
	path := ".obench_test_exit_code_baseline.json"
	defer _ = os.remove(path)
	{
		cfg := _exit_config()
		cfg.baseline_save_path = path
		s := obench.suite_create("saved", cfg)
		defer obench.suite_destroy(&s)
		obench.bench(&s, "old_name", _exit_step)
		testing.expect(t, obench.suite_run(&s))
	}
	cfg := _exit_config()
	cfg.baseline_load_path = path
	cfg.fail_on_regression = true
	s := obench.suite_create("saved", cfg)
	defer obench.suite_destroy(&s)
	obench.bench(&s, "new_name", _exit_step)
	testing.expect(t, !obench.suite_run(&s))
	testing.expect_value(t, s.failed_baseline, 1)
	testing.expect_value(t, s.failed_io, 0)
	testing.expect_value(t, obench.suite_exit_code(&s), obench.EXIT_BASELINE)
}

@(test)
test_comparison_exit_code :: proc(t: ^testing.T) {
	compared := obench.Comparison_Summary {
		matched = 3,
	}
	testing.expect_value(t, obench.comparison_exit_code(compared, true, true), obench.EXIT_SUCCESS)

	slower := compared
	slower.regressions = 1
	testing.expect_value(t, obench.comparison_exit_code(slower, true), obench.EXIT_FAILURE)
	testing.expect_value(t, obench.comparison_exit_code(slower), obench.EXIT_SUCCESS)

	other_build := slower
	other_build.build_mismatch = true
	testing.expect_value(t, obench.comparison_exit_code(other_build, true), obench.EXIT_BASELINE)
	// Allocation counts don't depend on the build, so the allocation gate alone still passes.
	testing.expect_value(
		t,
		obench.comparison_exit_code(other_build, false, true),
		obench.EXIT_SUCCESS,
	)

	counted := compared
	counted.alloc_counting_mismatch = true
	counted.errored = 1
	testing.expect_value(t, obench.comparison_exit_code(counted, true), obench.EXIT_FAILURE)

	disjoint := obench.Comparison_Summary {
		only_in_baseline  = 2,
		only_in_candidate = 2,
	}
	testing.expect_value(t, obench.comparison_exit_code(disjoint, true), obench.EXIT_BASELINE)
	testing.expect_value(
		t,
		obench.comparison_exit_code(disjoint, false, true),
		obench.EXIT_BASELINE,
	)
	testing.expect_value(t, obench.comparison_exit_code(disjoint), obench.EXIT_SUCCESS)
}
