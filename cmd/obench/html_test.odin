package main

import "core:testing"

@(test)
test_parse_cli_args_html :: proc(t: ^testing.T) {
	opts, err := parse_cli_args({"examples", "--html", "report.html"})
	defer destroy_cli_options(&opts)
	testing.expect_value(t, err, "")
	testing.expect_value(t, opts.html_path, "report.html")
}
