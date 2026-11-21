package obench_tests

import obench "../obench"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

// A baseline with three benchmarks, and a candidate where the first allocates more, the
// second failed, and the third is missing.
@(private = "file")
_comparison_docs :: proc() -> (baseline, candidate: obench.Export_Document) {
	names := [3]string{"grows", "breaks", "gone"}
	base := make([]obench.Export_Entry, 3, context.temp_allocator)
	for &e, i in base {
		e = {
			suite_name         = "s",
			samples            = 10,
			p50_ns             = 100,
			mean_ns            = 100,
			std_dev_ns         = 1,
			alloc_bytes_per_op = 64,
			allocs_per_op      = 1,
		}
		e.full_name = names[i]
	}
	cand := make([]obench.Export_Entry, 2, context.temp_allocator)
	cand[0] = base[0]
	cand[0].allocs_per_op = 2
	cand[0].alloc_bytes_per_op = 128
	cand[1] = {
		suite_name = "s",
		full_name  = "breaks",
		error      = "Loop_Exited_Early",
	}
	baseline = {
		format_version = obench.REPORT_FORMAT_VERSION,
		untimed_allocs = true,
		benchmarks     = base,
	}
	candidate = baseline
	candidate.benchmarks = cand
	return
}

@(test)
test_compare_documents_returns_a_row_per_match_and_failure :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	baseline, candidate := _comparison_docs()
	rows, summary := obench.compare_documents(baseline, candidate)
	testing.expect_value(t, len(rows), 2)
	testing.expect_value(t, summary.matched, 1)
	testing.expect_value(t, summary.errored, 1)
	testing.expect_value(t, summary.only_in_baseline, 1)
	testing.expect_value(t, summary.alloc_regressions, 1)
	testing.expect(t, rows[0].diff.allocs_grew)
	testing.expect_value(t, rows[1].error, "Loop_Exited_Early")
}

@(test)
test_comparison_markdown_puts_the_verdict_first :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	baseline, candidate := _comparison_docs()
	sb := strings.builder_make(context.temp_allocator)
	summary := obench.write_comparison_markdown(strings.to_writer(&sb), baseline, candidate)
	md := strings.to_string(sb)
	testing.expect_value(t, summary.alloc_regressions, 1)
	testing.expect(
		t,
		strings.has_prefix(md, "**obench compare:** 0 slower, 0 faster, 1 unchanged of 1 matched"),
		md,
	)
	testing.expect(t, strings.contains(md, "- 1 benchmark(s) failed in the candidate."), md)
	testing.expect(t, strings.contains(md, "<details><summary>2 benchmarks</summary>"), md)
	testing.expect(t, strings.contains(md, "| `grows` |"), md)
	testing.expect(t, strings.contains(md, "**allocs grew**"), md)
	testing.expect(t, strings.contains(md, "| `breaks` | 100.00 ns | - | **ERROR** |"), md)
}

@(test)
test_comparison_json_has_the_summary_and_a_verdict_per_benchmark :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	baseline, candidate := _comparison_docs()
	sb := strings.builder_make(context.temp_allocator)
	_, err := obench.write_comparison_json(strings.to_writer(&sb), baseline, candidate)
	testing.expect_value(t, err, nil)
	value, parse_err := json.parse_string(
		strings.to_string(sb),
		allocator = context.temp_allocator,
	)
	if !testing.expect_value(t, parse_err, nil) {
		return
	}
	root := value.(json.Object)
	summary := root["summary"].(json.Object)
	testing.expect_value(t, summary["matched"].(json.Float), 1)
	testing.expect_value(t, summary["alloc_regressions"].(json.Float), 1)
	benches := root["benchmarks"].(json.Array)
	testing.expect_value(t, len(benches), 2)
	testing.expect_value(t, benches[0].(json.Object)["verdict"].(json.String), "unchanged")
	testing.expect_value(t, benches[0].(json.Object)["allocs_grew"].(json.Boolean), true)
	testing.expect_value(t, benches[1].(json.Object)["verdict"].(json.String), "error")
}

@(test)
test_compare_prints_the_interval_and_expected_false_alarms :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	samples := []f64{100, 101, 99, 102, 98, 100.5, 99.5, 101.5, 98.5, 100}
	entry := obench.Export_Entry {
		suite_name = "s",
		full_name  = "a",
		samples    = len(samples),
		p50_ns     = 100,
		mean_ns    = 100,
		std_dev_ns = 1.2,
		samples_ns = samples,
	}
	entries := make([]obench.Export_Entry, 20, context.temp_allocator)
	for &e, i in entries {
		e = entry
		e.full_name = fmt.tprintf("bench_%d", i)
	}
	doc := obench.Export_Document {
		format_version = obench.REPORT_FORMAT_VERSION,
		benchmarks     = entries,
	}
	sb := strings.builder_make(context.temp_allocator)
	_ = obench.write_comparison(strings.to_writer(&sb), doc, doc, 2.0, false)
	out := strings.to_string(sb)
	testing.expect(
		t,
		strings.contains(out, "Expected false alarms: at most 1.0 of 20 (5% each)"),
		out,
	)
	testing.expect(t, strings.contains(out, "[-"), "the interval of the shift is printed")

	_, summary := obench.compare_documents(doc, doc, 2.0, context.temp_allocator)
	testing.expect_value(t, summary.expected_false_alarms, 1.0)
}

// Reports from two processes each, the candidate about 5% slower in both.
@(private = "file")
_two_process_docs :: proc() -> (baseline, candidate: obench.Export_Document) {
	entry :: proc(medians: []f64) -> []obench.Export_Entry {
		entries := make([]obench.Export_Entry, 1, context.temp_allocator)
		entries[0] = {
			suite_name         = "s",
			full_name          = "work",
			samples            = len(medians),
			p50_ns             = medians[0],
			mean_ns            = medians[0],
			samples_ns         = medians,
			process_medians_ns = medians,
		}
		return entries
	}
	baseline = {
		format_version = obench.REPORT_FORMAT_VERSION,
		untimed_allocs = true,
		processes      = 2,
		benchmarks     = entry({100, 101}),
	}
	candidate = baseline
	candidate.benchmarks = entry({105, 106})
	return
}

@(test)
test_compare_leaves_too_few_processes_undecided :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	baseline, candidate := _two_process_docs()

	sb := strings.builder_make(context.temp_allocator)
	summary := obench.write_comparison(strings.to_writer(&sb), baseline, candidate, 2.0, false)
	out := strings.to_string(sb)
	testing.expect_value(t, summary.matched, 1)
	testing.expect_value(t, summary.undecided, 1)
	testing.expect_value(t, summary.regressions, 0)
	testing.expect_value(t, summary.unchanged, 1)
	testing.expect(t, strings.contains(out, "too few for 95%"), out)
	testing.expect(t, !strings.contains(out, "SLOWER"), out)
	testing.expect(t, strings.contains(out, "run 4 or more on both sides"), out)

	// A gate that could decide nothing didn't pass: it's the status for "can't be compared".
	testing.expect_value(t, obench.comparison_exit_code(summary), obench.EXIT_SUCCESS)
	testing.expect_value(
		t,
		obench.comparison_exit_code(summary, fail_on_regression = true),
		obench.EXIT_BASELINE,
	)

	js := strings.builder_make(context.temp_allocator)
	_, json_err := obench.write_comparison_json(strings.to_writer(&js), baseline, candidate, 2.0)
	testing.expect_value(t, json_err, nil)
	testing.expect(t, strings.contains(strings.to_string(js), `"too_few_samples": true`))
	testing.expect(t, strings.contains(strings.to_string(js), `"verdict": "unchanged"`))
}
