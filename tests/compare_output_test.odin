package obench_tests

import obench "../obench"
import "core:encoding/json"
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
