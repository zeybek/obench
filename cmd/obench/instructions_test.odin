package main

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
