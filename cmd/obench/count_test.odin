package main

import "core:testing"

@(test)
test_parse_cli_args_count :: proc(t: ^testing.T) {
	{
		opts, err := parse_cli_args({"examples", "--count", "5", "--json", "r.json"})
		defer destroy_cli_options(&opts)
		testing.expect_value(t, err, "")
		testing.expect_value(t, opts.count, 5)
	}
	{
		opts, err := parse_cli_args({"examples"})
		defer destroy_cli_options(&opts)
		testing.expect_value(t, err, "")
		testing.expect_value(t, opts.count, 1)
	}
	bad := [][]string {
		{"--count", "0"},
		{"--count", "3", "--md", "r.md"},
		{"--count", "3", "--csv", "r.csv"},
		{"--count", "2", "--test"},
		{"--count", "2", "--instructions"},
	}
	for args in bad {
		opts, err := parse_cli_args(args)
		destroy_cli_options(&opts)
		testing.expectf(t, err != "", "%v should be a usage error", args)
	}
}
