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
