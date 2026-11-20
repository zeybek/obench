package main

import obench "../../obench"
import "core:encoding/json"
import "core:strings"
import "core:testing"

@(private = "file")
_export_doc :: proc() -> obench.Export_Document {
	metrics := make([]obench.Custom_Metric, 1, context.temp_allocator)
	metrics[0] = {
		unit  = "Hit %",
		value = 99.5,
	}
	entries := make([]obench.Export_Entry, 2, context.temp_allocator)
	entries[0] = {
		suite_name         = "s",
		full_name          = "grp::fast",
		samples            = 10,
		batch_size         = 100,
		min_ns             = 9,
		p50_ns             = 10,
		p99_ns             = 12,
		ci95_ns            = 0.5,
		allocs_per_op      = 1,
		alloc_bytes_per_op = 64,
		temp_allocs_per_op = 1,
		temp_bytes_per_op  = 32,
		custom_metrics     = metrics,
	}
	entries[1] = {
		suite_name = "s",
		full_name  = "grp::broken",
		error      = "Loop_Exited_Early",
	}
	return obench.Export_Document {
		format_version = obench.REPORT_FORMAT_VERSION,
		obench_version = "0.0.0",
		odin_version = "dev-2026-10",
		optimization = "Speed",
		os = "linux",
		arch = "amd64",
		benchmarks = entries,
	}
}

@(private = "file")
_export_string :: proc(t: ^testing.T, format: Export_Format) -> string {
	sb := strings.builder_make(context.temp_allocator)
	testing.expect_value(t, write_export(strings.to_writer(&sb), _export_doc(), format), nil)
	return strings.to_string(sb)
}

@(test)
test_export_bmf_has_latency_allocations_and_custom_metrics :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	out := _export_string(t, .BMF)
	value, err := json.parse_string(out, allocator = context.temp_allocator)
	if !testing.expect_value(t, err, nil) {
		return
	}
	report := value.(json.Object)
	testing.expect_value(t, len(report), 1) // the failed benchmark is left out
	fast := report["s/grp::fast"].(json.Object)
	latency := fast["latency"].(json.Object)
	testing.expect_value(t, latency["value"].(json.Float), 10)
	testing.expect_value(t, latency["lower_value"].(json.Float), 9)
	testing.expect_value(t, latency["upper_value"].(json.Float), 12)
	testing.expect_value(t, fast["allocs-per-op"].(json.Object)["value"].(json.Float), 1)
	testing.expect_value(t, fast["bytes-per-op"].(json.Object)["value"].(json.Float), 64)
	testing.expect_value(t, fast["temp-bytes-per-op"].(json.Object)["value"].(json.Float), 32)
	testing.expect_value(t, fast["hit--"].(json.Object)["value"].(json.Float), 99.5)
}

@(test)
test_export_gab_gbench_and_jsonl_parse :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	gab, gab_err := json.parse_string(_export_string(t, .GAB), allocator = context.temp_allocator)
	testing.expect_value(t, gab_err, nil)
	entries := gab.(json.Array)
	testing.expect_value(t, len(entries), 3) // time, allocs and bytes of the one that worked
	testing.expect_value(t, entries[0].(json.Object)["name"].(json.String), "s/grp::fast")
	testing.expect_value(t, entries[0].(json.Object)["unit"].(json.String), "ns")
	testing.expect_value(t, entries[2].(json.Object)["unit"].(json.String), "B")

	gb, gb_err := json.parse_string(_export_string(t, .GBench), allocator = context.temp_allocator)
	testing.expect_value(t, gb_err, nil)
	benches := gb.(json.Object)["benchmarks"].(json.Array)
	testing.expect_value(t, len(benches), 1)
	first := benches[0].(json.Object)
	testing.expect_value(t, first["real_time"].(json.Float), 10)
	testing.expect_value(t, first["time_unit"].(json.String), "ns")
	testing.expect_value(t, first["iterations"].(json.Float), 1000)

	lines := strings.split_lines(
		strings.trim_space(_export_string(t, .JSONL)),
		context.temp_allocator,
	)
	testing.expect_value(t, len(lines), 1)
	line, line_err := json.parse_string(lines[0], allocator = context.temp_allocator)
	testing.expect_value(t, line_err, nil)
	testing.expect_value(t, line.(json.Object)["os"].(json.String), "linux")
}

@(test)
test_parse_cli_args_export :: proc(t: ^testing.T) {
	{
		opts, err := parse_cli_args({"export", "--format", "gbench", "report.json"})
		defer destroy_cli_options(&opts)
		testing.expect_value(t, err, "")
		testing.expect_value(t, opts.subcommand, Subcommand.Export)
		testing.expect_value(t, opts.export_format, Export_Format.GBench)
		testing.expect_value(t, opts.export_path, "report.json")
	}
	for bad in ([][]string{{"export", "report.json"}, {"export", "--format", "xml", "r.json"}, {"export", "--format", "bmf"}}) {
		opts, err := parse_cli_args(bad)
		defer destroy_cli_options(&opts)
		testing.expect(t, err != "", "expected a usage error")
	}
}
