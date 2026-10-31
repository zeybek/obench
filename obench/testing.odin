package obench

import "base:runtime"
import "core:log"
import "core:strings"
import "core:testing"

/*
Runs `s` from an `odin test` procedure.

The report is logged at Info level without colors, and the test fails when the suite has a
misused benchmark, a failed `@zero_alloc` check, a regression with `fail_on_regression`, or
a report file that could not be read or written. Benchmarks only mean something in optimized
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
	testing.expectf(
		t,
		ok,
		"obench suite %q failed: %d errors, %d @zero_alloc failures, %d regressions, %d file errors",
		s.name,
		s.failed_errors,
		s.failed_zero_alloc,
		s.failed_regressions,
		s.failed_io,
		loc = loc,
	)
}
