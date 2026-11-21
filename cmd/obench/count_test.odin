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

@(test)
test_few_processes_get_a_warning :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, few_processes_warning("--count", 1), "")
	testing.expect(t, few_processes_warning("--count", 2) != "")
	testing.expect(t, few_processes_warning("--rounds", 3) != "")
	testing.expect_value(t, few_processes_warning("--count", 4), "")
	testing.expect_value(t, few_processes_warning("--rounds", 6), "")
}
