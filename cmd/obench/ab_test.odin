package main

import "core:testing"

@(test)
test_parse_cli_args_compare_sides_and_ab :: proc(t: ^testing.T) {
	{
		opts, err := parse_cli_args(
			{"compare", "a1.json", "a2.json", "--", "b1.json", "b2.json", "--fail-on-regression"},
		)
		defer destroy_cli_options(&opts)
		testing.expect_value(t, err, "")
		testing.expect_value(t, len(opts.compare_old_files), 2)
		testing.expect_value(t, len(opts.compare_new_files), 2)
		testing.expect_value(t, opts.compare_new_files[1], "b2.json")
		testing.expect(t, opts.fail_on_regression, "an option after -- still counts")
	}
	{
		opts, err := parse_cli_args({"ab", "../main", ".", "--rounds", "8"})
		defer destroy_cli_options(&opts)
		testing.expect_value(t, err, "")
		testing.expect_value(t, opts.subcommand, Subcommand.AB)
		testing.expect_value(t, opts.ab_baseline, "../main")
		testing.expect_value(t, opts.ab_candidate, ".")
		testing.expect_value(t, opts.rounds, 8)
	}
	{
		opts, err := parse_cli_args({"ab", "a", "b"})
		defer destroy_cli_options(&opts)
		testing.expect_value(t, err, "")
		testing.expect_value(t, opts.rounds, DEFAULT_AB_ROUNDS)
	}
	bad := [][]string {
		{"compare", "a.json", "--"},
		{"compare", "--", "b.json"},
		{"compare", "a.json", "b.json", "c.json"},
		{"ab", "a"},
		{"ab", "a", "b", "--rounds", "1"},
	}
	for args in bad {
		opts, err := parse_cli_args(args)
		destroy_cli_options(&opts)
		testing.expectf(t, err != "", "%v should be a usage error", args)
	}
}
