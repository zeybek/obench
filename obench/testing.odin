package obench

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:testing"

/*
Runs `s` from an `odin test` procedure.

The report is logged at Info level without colors, and the test fails when the suite has a
misused benchmark, a failed `@zero_alloc` check, a regression with `fail_on_regression` or
`fail_on_alloc_regression`, or a report file that could not be read or written. Each problem
is its own failure that names its benchmark (see `suite_failure_messages`), so the test
output says which benchmark failed and why. Benchmarks only mean something in optimized
builds, so run them with `odin test <dir> -o:speed`; the report warns otherwise.

Example:
	package my_benchmarks

	import "core:testing"
	import obench "libs/obench"

	@(test)
	sorting :: proc(t: ^testing.T) {
		s := obench.suite_create("sorting")
		defer obench.suite_destroy(&s)
		obench.bench(&s, "slice_sort", slice_sort_bench)
		obench.run_test(t, &s)
	}
*/
run_test :: proc(t: ^testing.T, s: ^Suite, loc := #caller_location) {
	scratch := runtime.Arena {
		backing_allocator = s.allocator,
	}
	defer runtime.arena_destroy(&scratch)
	context.temp_allocator = runtime.arena_allocator(&scratch)

	ok := _suite_execute(s)

	color := s.config.color_output
	s.config.color_output = false
	report := strings.builder_make(context.temp_allocator)
	write_terminal_report(strings.to_writer(&report), s)
	s.config.color_output = color

	log.info(strings.to_string(report), location = loc)
	messages := suite_failure_messages(s)
	for msg in messages {
		testing.expect(t, false, msg, loc = loc)
	}
	// Every failure counted above has a message; this only catches one that doesn't.
	if !ok && len(messages) == 0 {
		testing.expectf(t, false, "obench suite %q failed", s.name, loc = loc)
	}
}

/*
Returns one message for every problem the last `suite_run` or `run_test` found in `s`, each
naming its benchmark: a misused `Bencher`, a failed `@zero_alloc` check, a regression that
fails the run under `fail_on_regression`, or more allocations under
`fail_on_alloc_regression`. Problems that belong to no benchmark, such as a baseline or report
file that could not be read or written, get one message for the suite, since their warnings
were already printed. The messages are allocated with `allocator`.
*/
@(require_results)
suite_failure_messages :: proc(s: ^Suite, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for r in s.results {
		if r.error != .None {
			append(
				&out,
				fmt.aprintf(
					"%s: %s",
					r.full_name,
					bench_error_message(r.error),
					allocator = allocator,
				),
			)
			continue
		}
		if r.zero_alloc_failed {
			append(
				&out,
				fmt.aprintf(
					"%s: allocated %d B on the heap in a @zero_alloc benchmark, first at %v",
					r.full_name,
					r.violation_size,
					r.violation_loc,
					allocator = allocator,
				),
			)
		}
		if r.diff.is_regression && s.config.fail_on_regression {
			test :=
				r.diff.rank_test ? fmt.tprintf("95%% interval %+.1f%% to %+.1f%%", r.diff.shift_low_pct, r.diff.shift_high_pct) : "Welch's t-test"
			append(
				&out,
				fmt.aprintf(
					"%s: %+.1f%% slower than the baseline at p50 (%s)",
					r.full_name,
					r.diff.delta_median_pct,
					test,
					allocator = allocator,
				),
			)
		}
		if r.diff.allocs_grew && s.config.fail_on_alloc_regression {
			append(
				&out,
				fmt.aprintf(
					"%s: allocates more per operation than in the baseline (%.1f allocs, %s now)",
					r.full_name,
					r.stats.allocs_per_op,
					format_bytes(r.stats.alloc_bytes_per_op),
					allocator = allocator,
				),
			)
		}
	}
	if s.failed_io > 0 {
		append(
			&out,
			fmt.aprintf(
				"obench suite %q: %d baseline, trace, or report file problem(s); see the warnings above",
				s.name,
				s.failed_io,
				allocator = allocator,
			),
		)
	}
	return out[:]
}
