package main

import "core:testing"

@(test)
test_worse_exit_code :: proc(t: ^testing.T) {
	testing.expect_value(t, worse_exit_code(0, 0), 0)
	testing.expect_value(t, worse_exit_code(0, EXIT_BASELINE), EXIT_BASELINE)
	testing.expect_value(t, worse_exit_code(EXIT_BASELINE, EXIT_FAILURE), EXIT_FAILURE)
	testing.expect_value(t, worse_exit_code(EXIT_FAILURE, EXIT_BASELINE), EXIT_FAILURE)
	// A crash or any other status counts as a failure.
	testing.expect_value(t, worse_exit_code(0, 139), EXIT_FAILURE)
	testing.expect_value(t, worse_exit_code(EXIT_USAGE, 0), EXIT_FAILURE)
}
