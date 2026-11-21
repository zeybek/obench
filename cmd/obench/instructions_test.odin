package main

import "core:os"
import "core:testing"

@(test)
test_parse_cli_args_instructions :: proc(t: ^testing.T) {
	opts, err := parse_cli_args(
		{"examples", "--instructions", "--batch-size", "200", "--fail-on-regression"},
	)
	defer destroy_cli_options(&opts)
	testing.expect_value(t, err, "")
	testing.expect(t, opts.instructions)
	testing.expect_value(t, opts.batch_size, 200)
	testing.expect(t, opts.fail_on_regression)
}

// `--instructions` runs every benchmark alone under Cachegrind and nothing else, so the flags
// it couldn't honor are usage errors and not silently ignored.
@(test)
test_instructions_refuses_the_flags_it_cant_honor :: proc(t: ^testing.T) {
	refused := [][]string {
		{"--fail-on-alloc-regression"},
		{"--zero-alloc"},
		{"--test"},
		{"--md", "r.md"},
		{"--csv", "r.csv"},
		{"--html", "r.html"},
		{"--spall", "r.spall"},
	}
	for flags in refused {
		args := make([dynamic]string, context.temp_allocator)
		append(&args, "examples", "--instructions")
		append(&args, ..flags)
		opts, err := parse_cli_args(args[:])
		defer destroy_cli_options(&opts)
		testing.expectf(t, err != "", "%v: expected a usage error", flags)
	}
	free_all(context.temp_allocator)

	// What it does use still parses.
	opts, err := parse_cli_args(
		{
			"examples",
			"--instructions",
			"-f",
			"sort",
			"--batch-size",
			"50",
			"--baseline",
			"b.json",
			"--save-baseline",
			"n.json",
			"--json",
			"r.json",
			"--threshold",
			"1",
			"--fail-on-regression",
		},
	)
	defer destroy_cli_options(&opts)
	testing.expect_value(t, err, "")
}

@(test)
test_an_instruction_baseline_that_cant_be_read_fails :: proc(t: ^testing.T) {
	dir :: ".obench_test_instruction_baselines"
	testing.expect_value(t, os.make_directory(dir), nil)
	defer _ = os.remove_all(dir)
	write :: proc(t: ^testing.T, path, content: string) {
		testing.expect_value(t, os.write_entire_file(path, content), nil)
	}
	broken :: dir + "/broken.json"
	times :: dir + "/times.json"
	counts :: dir + "/counts.json"
	write(t, broken, "{\"format\": ")
	write(t, times, `{"format_version": 6, "suite_name": "s", "benchmarks": []}`)
	write(t, counts, `{"format": "obench-instructions", "format_version": 1, "benchmarks": []}`)

	// A misspelled path or a broken file fails the run, so it doesn't pass for a baseline to
	// save again. A report of another kind can be saved again.
	_, code := read_instruction_baseline(dir + "/missing.json")
	testing.expect_value(t, code, EXIT_FAILURE)
	_, code = read_instruction_baseline(broken)
	testing.expect_value(t, code, EXIT_FAILURE)
	_, code = read_instruction_baseline(times)
	testing.expect_value(t, code, EXIT_BASELINE)
	report: Instruction_Report
	report, code = read_instruction_baseline(counts)
	testing.expect_value(t, code, EXIT_SUCCESS)
	testing.expect_value(t, report.format, INSTRUCTIONS_FORMAT)
}
