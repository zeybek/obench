package main

import "core:slice"
import "core:testing"

@(test)
test_parse_cli_args_pin :: proc(t: ^testing.T) {
	{
		opts, err := parse_cli_args({"examples", "--pin", "2"})
		defer destroy_cli_options(&opts)
		testing.expect_value(t, err, "")
		testing.expect_value(t, opts.pin_cpu, 2)
		testing.expect(t, slice.contains(_runtime_args(opts, Package_Outputs{}), "--pin"))
	}
	{
		opts, err := parse_cli_args({"examples"})
		defer destroy_cli_options(&opts)
		testing.expect_value(t, err, "")
		testing.expect_value(t, opts.pin_cpu, -1)
	}
	opts, err := parse_cli_args({"examples", "--pin", "-1"})
	defer destroy_cli_options(&opts)
	testing.expect(t, err != "", "a negative CPU is a usage error")
}

@(test)
test_parse_cli_args_counters :: proc(t: ^testing.T) {
	opts, err := parse_cli_args({"examples", "--counters"})
	defer destroy_cli_options(&opts)
	testing.expect_value(t, err, "")
	testing.expect(t, opts.counters)
	testing.expect(t, slice.contains(_runtime_args(opts, Package_Outputs{}), "--counters"))
}
