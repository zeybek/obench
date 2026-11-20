package main

import "core:slice"
import "core:testing"

@(test)
test_parse_cli_args_selection_and_budget :: proc(t: ^testing.T) {
	opts, err := parse_cli_args(
		{
			"examples",
			"-f",
			`odin_map\[(8|64)\]`,
			"--skip",
			"linear",
			"--exact",
			"lookup_by_key::odin_map[64]",
			"--max-time",
			"200ms",
			"--min-sample-time",
			"500us",
			"--batch-size",
			"1000",
			"-q",
		},
	)
	defer destroy_cli_options(&opts)
	testing.expect_value(t, err, "")
	testing.expect_value(t, opts.filter, `odin_map\[(8|64)\]`)
	testing.expect_value(t, opts.skip, "linear")
	testing.expect_value(t, opts.exact, "lookup_by_key::odin_map[64]")
	testing.expect_value(t, opts.max_time, "200ms")
	testing.expect_value(t, opts.min_sample_time, "500us")
	testing.expect_value(t, opts.batch_size, 1000)
	testing.expect(t, opts.quiet)

	args := _runtime_args(opts, Package_Outputs{})
	for want in ([]string{"--skip", "--exact", "--max-time", "--min-sample-time", "--batch-size", "-q"}) {
		testing.expectf(t, slice.contains(args, want), "%s is not forwarded: %v", want, args)
	}
}

@(test)
test_parse_cli_args_test_mode_and_list_json :: proc(t: ^testing.T) {
	{
		opts, err := parse_cli_args({"examples", "--test"})
		defer destroy_cli_options(&opts)
		testing.expect_value(t, err, "")
		testing.expect(t, opts.test_mode)
		testing.expect(t, slice.contains(_runtime_args(opts, Package_Outputs{}), "--test"))
	}
	{
		opts, err := parse_cli_args({"list", "examples", "--json"})
		defer destroy_cli_options(&opts)
		testing.expect_value(t, err, "")
		testing.expect_value(t, opts.subcommand, Subcommand.List)
		testing.expect(t, opts.list_json)
		testing.expect_value(t, opts.target_path, "examples")
	}
	bad := [][]string {
		{"--test", "--baseline", "main.json"},
		{"--test", "--fail-on-regression"},
		{"--max-time", "200"},
		{"--min-sample-time", "fast"},
		{"--batch-size", "0"},
	}
	for args in bad {
		opts, err := parse_cli_args(args)
		destroy_cli_options(&opts)
		testing.expectf(t, err != "", "%v should be a usage error", args)
	}
}
