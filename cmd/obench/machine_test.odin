package main

import "core:testing"

@(test)
test_parse_cli_args_machine_label :: proc(t: ^testing.T) {
	opts, err := parse_cli_args({"examples", "--machine", "ci-box"})
	defer destroy_cli_options(&opts)
	testing.expect_value(t, err, "")
	testing.expect_value(t, opts.machine, "ci-box")
}
