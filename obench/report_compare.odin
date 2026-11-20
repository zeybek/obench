package obench

import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:math"
import "core:os"
import "core:strings"
import "core:text/table"

/*
Counts from comparing two reports with `write_comparison`.
*/
Comparison_Summary :: struct {
	matched:                 int,
	improvements:            int,
	regressions:             int,
	unchanged:               int,
	only_in_baseline:        int,
	only_in_candidate:       int,
	// Benchmarks that worked in the baseline but failed in the candidate.
	errored:                 int,
	// Matched benchmarks whose heap or temp allocations or bytes per operation went up.
	alloc_regressions:       int,
	geomean_delta_pct:       f64,
	// How many of the matched benchmarks the noise between samples would flag on average, at
	// most: each interval has a 5% chance of missing the true change. A machine that ran at
	// another speed between the two runs shifts every sample of one run, which this doesn't
	// cover.
	expected_false_alarms:   f64,
	// The reports come from builds with a different optimization mode, OS, or architecture,
	// so their timings can't be compared.
	build_mismatch:          bool,
	// The reports counted allocations differently (see `Config.untimed_alloc_check`) and the
	// baseline has a benchmark that allocates, whose times therefore can't be compared.
	alloc_counting_mismatch: bool,
}

@(private = "file")
_match_key :: proc(e: Export_Entry) -> string {
	return fmt.tprintf("%s\x00%s", e.suite_name, e.full_name)
}

/*
One benchmark of a comparison: found in both reports, or failed in the candidate after it
worked in the baseline, in which case `error` holds the candidate's error and `diff` is empty.
*/
Comparison_Row :: struct {
	suite_name:            string,
	full_name:             string,
	baseline_p50_ns:       f64,
	current_p50_ns:        f64,
	baseline_bytes_per_op: f64,
	current_bytes_per_op:  f64,
	diff:                  Baseline_Diff,
	error:                 string,
}

/*
Matches the benchmarks of `candidate` with those of `baseline` by suite and full name and
compares every pair with `compare_baseline`. Returns a row for each match and for each
benchmark that worked in the baseline but failed in the candidate, in the candidate's order,
and the summary. The rows are allocated with `allocator`; `write_comparison`,
`write_comparison_markdown`, and `write_comparison_json` print them.
*/
@(require_results)
compare_documents :: proc(
	baseline, candidate: Export_Document,
	noise_threshold_pct: f64 = 2.0,
	allocator := context.temp_allocator,
) -> (
	rows: []Comparison_Row,
	summary: Comparison_Summary,
) {
	baseline_by_key := make(map[string]Export_Entry, context.temp_allocator)
	for &e in baseline.benchmarks {
		if e.error == "" {
			baseline_by_key[_match_key(e)] = e
		}
	}
	summary.build_mismatch = _builds_differ(_document_build(baseline), _document_build(candidate))
	if baseline.untimed_allocs != candidate.untimed_allocs {
		for &e in baseline.benchmarks {
			if e.error == "" &&
			   _allocates(e.allocs_per_op, e.resizes_per_op, e.temp_allocs_per_op) {
				summary.alloc_counting_mismatch = true
				break
			}
		}
	}

	out := make([dynamic]Comparison_Row, allocator)
	seen := make(map[string]bool, context.temp_allocator)
	ratio_log_sum: f64 = 0
	ratio_count := 0
	for &e in candidate.benchmarks {
		key := _match_key(e)
		old_e, exists := baseline_by_key[key]
		if e.error != "" {
			if exists {
				seen[key] = true
				summary.errored += 1
				append(
					&out,
					Comparison_Row {
						suite_name = e.suite_name,
						full_name = e.full_name,
						baseline_p50_ns = old_e.p50_ns,
						baseline_bytes_per_op = old_e.alloc_bytes_per_op,
						error = e.error,
					},
				)
			}
			continue
		}
		if !exists {
			summary.only_in_candidate += 1
			continue
		}
		seen[key] = true
		old_st := _export_entry_stats(old_e)
		new_st := _export_entry_stats(e)
		diff := compare_baseline(new_st, old_st, noise_threshold_pct)
		summary.matched += 1
		if diff.allocs_grew {
			summary.alloc_regressions += 1
		}
		if ratio := 1.0 + diff.delta_median_pct / 100.0; diff.has_baseline && ratio > 0 {
			ratio_log_sum += math.ln(ratio)
			ratio_count += 1
		}
		switch {
		case diff.is_improvement:
			summary.improvements += 1
		case diff.is_regression:
			summary.regressions += 1
		case:
			summary.unchanged += 1
		}
		append(
			&out,
			Comparison_Row {
				suite_name = e.suite_name,
				full_name = e.full_name,
				baseline_p50_ns = old_st.p50_ns,
				current_p50_ns = new_st.p50_ns,
				baseline_bytes_per_op = old_st.alloc_bytes_per_op,
				current_bytes_per_op = new_st.alloc_bytes_per_op,
				diff = diff,
			},
		)
	}
	for key in baseline_by_key {
		if key not_in seen {
			summary.only_in_baseline += 1
		}
	}
	if ratio_count > 0 {
		summary.geomean_delta_pct = (math.exp(ratio_log_sum / f64(ratio_count)) - 1.0) * 100.0
	}
	summary.expected_false_alarms = 0.05 * f64(summary.matched)
	return out[:], summary
}

// The benchmark's name in a comparison: with its suite when the report holds several.
@(private = "file")
_row_name :: proc(r: Comparison_Row, several_suites: bool) -> string {
	return several_suites ? fmt.tprintf("%s/%s", r.suite_name, r.full_name) : r.full_name
}

// `[+1.2%, +3.4%] p=0.0123`, the 95% interval of the shift and the Mann-Whitney U p-value, or
// `|t|=2.31` for Welch's t-test when a report has no samples.
@(private = "file")
_significance :: proc(diff: Baseline_Diff) -> string {
	switch {
	case diff.rank_test:
		return fmt.tprintf(
			"[%+.1f%%, %+.1f%%] p=%.4f",
			diff.shift_low_pct,
			diff.shift_high_pct,
			diff.p_value,
		)
	case math.is_inf(diff.welch_t, 0):
		return "|t|=inf"
	}
	return fmt.tprintf("|t|=%.2f", abs(diff.welch_t))
}

// `64 B → 128 B (+100.0%)`, or `0 B → 0 B` when neither side allocates.
@(private = "file")
_bytes_change :: proc(r: Comparison_Row) -> string {
	if r.baseline_bytes_per_op > 0 || r.current_bytes_per_op > 0 {
		return fmt.tprintf(
			"%s → %s (%+.1f%%)",
			format_bytes(r.baseline_bytes_per_op),
			format_bytes(r.current_bytes_per_op),
			r.diff.delta_bytes_pct,
		)
	}
	return "0 B → 0 B"
}

/*
Writes a `benchstat`-style comparison of `candidate` against `baseline` to `w`: median
delta, the significance test (the Mann-Whitney U p-value, or Welch's |t| when a report has
no samples), and bytes per operation for every benchmark found in both (matched by suite and
full name), followed by a summary line.
*/
write_comparison :: proc(
	w: io.Writer,
	baseline, candidate: Export_Document,
	noise_threshold_pct: f64 = 2.0,
	color_output := true,
) -> (
	summary: Comparison_Summary,
) {
	p := _palette(color_output)
	rows: []Comparison_Row
	rows, summary = compare_documents(baseline, candidate, noise_threshold_pct)
	several_suites := _has_several_suites(candidate.benchmarks)

	if summary.build_mismatch {
		fmt.wprintf(
			w,
			"%swarning:%s the baseline was built with %s and the candidate with %s; their timings can't be compared\n",
			p.red,
			p.reset,
			_build_string(_document_build(baseline)),
			_build_string(_document_build(candidate)),
		)
	}
	if summary.alloc_counting_mismatch {
		fmt.wprintf(
			w,
			"%swarning:%s the baseline counted allocations %s and the candidate %s; the times of benchmarks that allocate can't be compared\n",
			p.red,
			p.reset,
			_alloc_counting_string(baseline.untimed_allocs),
			_alloc_counting_string(candidate.untimed_allocs),
		)
	}

	rt: _Report_Table
	tbl := _report_table_init(&rt)
	defer _report_table_destroy(&rt)
	table.header(
		tbl,
		"benchmark",
		"baseline(p50)",
		"current(p50)",
		"delta",
		"significance",
		"bytes/op",
	)
	for col in 1 ..< 5 {
		table.set_cell_alignment(tbl, table.header_row(tbl), col, .Right)
	}

	for r in rows {
		table.row(tbl)
		row := table.last_row(tbl)
		_set_cell(tbl, row, 0, _row_name(r, several_suites), .Left)
		_set_cell(tbl, row, 1, format_duration_ns(r.baseline_p50_ns))
		if r.error != "" {
			_set_cell(tbl, row, 2, "-")
			_set_cell(tbl, row, 3, fmt.tprintf("%sERROR%s", p.red, p.reset))
			_set_cell(tbl, row, 4, "-")
			_set_cell(tbl, row, 5, r.error, .Left)
			continue
		}

		delta_color, verdict := p.dim, "~"
		switch {
		case r.diff.is_improvement:
			delta_color, verdict = p.green, "faster"
		case r.diff.is_regression:
			delta_color, verdict = p.red, "SLOWER"
		}
		bytes_str := _bytes_change(r)
		if r.diff.allocs_grew {
			bytes_str = fmt.tprintf("%s %sallocs grew%s", bytes_str, p.red, p.reset)
		}

		_set_cell(tbl, row, 2, format_duration_ns(r.current_p50_ns))
		_set_cell(
			tbl,
			row,
			3,
			fmt.tprintf("%s%+.2f%% %s%s", delta_color, r.diff.delta_median_pct, verdict, p.reset),
		)
		_set_cell(tbl, row, 4, _significance(r.diff))
		_set_cell(tbl, row, 5, bytes_str, .Left)
	}

	table.build(tbl, _ansi_width_proc)
	rule := strings.repeat("─", _table_width(tbl, len(" | ")), context.temp_allocator)
	fmt.wprintf(w, "%s%s%s\n", p.dim, rule, p.reset)
	io.write_string(w, p.bold)
	_write_table_row(w, tbl, table.header_row(tbl), " │ ")
	io.write_string(w, p.reset)
	fmt.wprintf(w, "%s%s%s\n", p.dim, rule, p.reset)
	for row in 1 ..< tbl.nr_rows {
		_write_table_row(w, tbl, row, " │ ")
	}
	fmt.wprintf(w, "%s%s%s\n", p.dim, rule, p.reset)

	fmt.wprintf(
		w,
		"Summary: %d matched │ geomean delta: %s%+.2f%%%s (%s%d faster%s, %s%d slower%s, %d unchanged)\n",
		summary.matched,
		p.bold,
		summary.geomean_delta_pct,
		p.reset,
		p.green,
		summary.improvements,
		p.reset,
		p.red,
		summary.regressions,
		p.reset,
		summary.unchanged,
	)
	if summary.matched > 0 {
		fmt.wprintf(
			w,
			"%sExpected false alarms: at most %.1f of %d (5%% each), more if the machine ran at another speed between the two runs%s\n",
			p.dim,
			summary.expected_false_alarms,
			summary.matched,
			p.reset,
		)
	}
	if summary.alloc_regressions > 0 {
		fmt.wprintf(
			w,
			"%s%d benchmark(s) allocate more per operation than in the baseline%s\n",
			p.red,
			summary.alloc_regressions,
			p.reset,
		)
	}
	if summary.errored > 0 {
		fmt.wprintf(
			w,
			"%s%d benchmark(s) failed in the candidate%s\n",
			p.red,
			summary.errored,
			p.reset,
		)
	}
	if summary.only_in_baseline > 0 || summary.only_in_candidate > 0 {
		fmt.wprintf(
			w,
			"%s%d only in baseline, %d only in candidate (not compared)%s\n",
			p.dim,
			summary.only_in_baseline,
			summary.only_in_candidate,
			p.reset,
		)
	}
	return
}

/*
Writes the comparison of `candidate` against `baseline` as GitHub-flavored Markdown, for a job
summary or a pull request comment: a one-line verdict first, then the warnings, then every
benchmark in a table inside a `<details>` block.
*/
write_comparison_markdown :: proc(
	w: io.Writer,
	baseline, candidate: Export_Document,
	noise_threshold_pct: f64 = 2.0,
) -> (
	summary: Comparison_Summary,
) {
	rows: []Comparison_Row
	rows, summary = compare_documents(baseline, candidate, noise_threshold_pct)
	several_suites := _has_several_suites(candidate.benchmarks)

	fmt.wprintf(
		w,
		"**obench compare:** %d slower, %d faster, %d unchanged of %d matched, geomean %+.2f%% (threshold %.1f%%). Expected false alarms: at most %.1f, more if the machine ran at another speed between the two runs.\n\n",
		summary.regressions,
		summary.improvements,
		summary.unchanged,
		summary.matched,
		summary.geomean_delta_pct,
		noise_threshold_pct,
		summary.expected_false_alarms,
	)
	warned := false
	if summary.build_mismatch {
		fmt.wprintf(
			w,
			"- The baseline was built with %s and the candidate with %s, so their timings can't be compared.\n",
			_build_string(_document_build(baseline)),
			_build_string(_document_build(candidate)),
		)
		warned = true
	}
	if summary.alloc_counting_mismatch {
		fmt.wprintf(
			w,
			"- The baseline counted allocations %s and the candidate %s, so the times of benchmarks that allocate can't be compared.\n",
			_alloc_counting_string(baseline.untimed_allocs),
			_alloc_counting_string(candidate.untimed_allocs),
		)
		warned = true
	}
	if summary.alloc_regressions > 0 {
		fmt.wprintf(
			w,
			"- %d benchmark(s) allocate more per operation than in the baseline.\n",
			summary.alloc_regressions,
		)
		warned = true
	}
	if summary.errored > 0 {
		fmt.wprintf(w, "- %d benchmark(s) failed in the candidate.\n", summary.errored)
		warned = true
	}
	if summary.only_in_baseline > 0 || summary.only_in_candidate > 0 {
		fmt.wprintf(
			w,
			"- %d only in the baseline and %d only in the candidate weren't compared.\n",
			summary.only_in_baseline,
			summary.only_in_candidate,
		)
		warned = true
	}
	if warned {
		io.write_string(w, "\n")
	}

	fmt.wprintf(w, "<details><summary>%d benchmarks</summary>\n\n", len(rows))
	io.write_string(
		w,
		"| benchmark | baseline (p50) | current (p50) | delta | significance | bytes/op |\n",
	)
	io.write_string(w, "|:--|--:|--:|--:|--:|:--|\n")
	for r in rows {
		name, _ := strings.replace_all(
			_row_name(r, several_suites),
			"|",
			"\\|",
			context.temp_allocator,
		)
		if r.error != "" {
			fmt.wprintf(
				w,
				"| `%s` | %s | - | **ERROR** | - | %s |\n",
				name,
				format_duration_ns(r.baseline_p50_ns),
				r.error,
			)
			continue
		}
		verdict := "~"
		switch {
		case r.diff.is_improvement:
			verdict = "faster"
		case r.diff.is_regression:
			verdict = "**SLOWER**"
		}
		bytes_str := _bytes_change(r)
		if r.diff.allocs_grew {
			bytes_str = fmt.tprintf("%s **allocs grew**", bytes_str)
		}
		fmt.wprintf(
			w,
			"| `%s` | %s | %s | %+.2f%% %s | %s | %s |\n",
			name,
			format_duration_ns(r.baseline_p50_ns),
			format_duration_ns(r.current_p50_ns),
			r.diff.delta_median_pct,
			verdict,
			_significance(r.diff),
			bytes_str,
		)
	}
	io.write_string(w, "\n</details>\n")
	return
}

@(private = "file")
_JSON_Comparison_Row :: struct {
	suite:                 string `json:"suite"`,
	name:                  string `json:"name"`,
	verdict:               string `json:"verdict"`, // faster, slower, unchanged, or error
	baseline_p50_ns:       f64 `json:"baseline_p50_ns"`,
	current_p50_ns:        f64 `json:"current_p50_ns"`,
	delta_median_pct:      f64 `json:"delta_median_pct"`,
	test:                  string `json:"test"`, // mann-whitney or welch
	p_value:               f64 `json:"p_value"`,
	welch_t:               f64 `json:"welch_t"`,
	shift_pct:             f64 `json:"shift_pct"`, // Hodges-Lehmann shift, with its 95% interval
	shift_low_pct:         f64 `json:"shift_low_pct"`,
	shift_high_pct:        f64 `json:"shift_high_pct"`,
	baseline_bytes_per_op: f64 `json:"baseline_bytes_per_op"`,
	current_bytes_per_op:  f64 `json:"current_bytes_per_op"`,
	delta_bytes_pct:       f64 `json:"delta_bytes_pct"`,
	allocs_grew:           bool `json:"allocs_grew"`,
	error:                 string `json:"error,omitempty"`,
}

@(private = "file")
_JSON_Comparison :: struct {
	threshold_pct: f64 `json:"threshold_pct"`,
	summary:       Comparison_Summary `json:"summary"`,
	benchmarks:    []_JSON_Comparison_Row `json:"benchmarks"`,
}

/*
Writes the comparison of `candidate` against `baseline` as JSON, so a bot doesn't have to
read the table or redo the statistics: the threshold, the `Comparison_Summary`, and for every
benchmark its verdict (`faster`, `slower`, `unchanged`, or `error`), the medians, the delta,
the test with its p-value or Welch's t (0 when infinite), and the bytes per operation.
*/
write_comparison_json :: proc(
	w: io.Writer,
	baseline, candidate: Export_Document,
	noise_threshold_pct: f64 = 2.0,
) -> (
	summary: Comparison_Summary,
	err: io.Error,
) {
	rows: []Comparison_Row
	rows, summary = compare_documents(baseline, candidate, noise_threshold_pct)
	out := make([]_JSON_Comparison_Row, len(rows), context.temp_allocator)
	for r, i in rows {
		o := &out[i]
		o.suite = r.suite_name
		o.name = r.full_name
		o.baseline_p50_ns = r.baseline_p50_ns
		o.baseline_bytes_per_op = r.baseline_bytes_per_op
		if r.error != "" {
			o.verdict = "error"
			o.error = r.error
			continue
		}
		switch {
		case r.diff.is_improvement:
			o.verdict = "faster"
		case r.diff.is_regression:
			o.verdict = "slower"
		case:
			o.verdict = "unchanged"
		}
		o.current_p50_ns = r.current_p50_ns
		o.delta_median_pct = r.diff.delta_median_pct
		o.test = r.diff.rank_test ? "mann-whitney" : "welch"
		o.p_value = r.diff.p_value
		o.welch_t =
			math.is_inf(r.diff.welch_t, 0) || math.is_nan(r.diff.welch_t) ? 0 : r.diff.welch_t
		o.shift_pct = r.diff.shift_pct
		o.shift_low_pct = r.diff.shift_low_pct
		o.shift_high_pct = r.diff.shift_high_pct
		o.current_bytes_per_op = r.current_bytes_per_op
		o.delta_bytes_pct = r.diff.delta_bytes_pct
		o.allocs_grew = r.diff.allocs_grew
	}
	report := _JSON_Comparison {
		threshold_pct = noise_threshold_pct,
		summary       = summary,
		benchmarks    = out,
	}
	opt := json.Marshal_Options {
		pretty     = true,
		use_spaces = true,
		spaces     = 2,
	}
	// `json.marshal` rather than `json.marshal_to_writer`, which takes its options by pointer in
	// Odin dev-2026-10 and by value from dev-2026-11a on.
	data, marshal_err := json.marshal(report, opt, context.temp_allocator)
	if marshal_err != nil {
		return summary, .Unknown
	}
	io.write(w, data) or_return
	io.write_byte(w, '\n') or_return
	return summary, nil
}

/*
Compares two saved JSON reports in `benchstat` style and prints the result to stdout
(see `write_comparison`).

`passed` is `false` when `fail_on_regression` is set and something regressed, a benchmark
that worked in the baseline failed in the candidate, the two reports come from builds with a
different optimization mode, OS, or architecture, or they counted allocations differently
while the baseline has a benchmark that allocates. It is also `false` when
`fail_on_alloc_regression` is set and a benchmark allocates more per operation (heap or temp,
count or bytes) than in the baseline. Benchmarks missing from one side are listed but don't
fail the comparison (a candidate run may use a filter).
*/
@(require_results)
compare_baseline_files :: proc(
	old_path: string,
	new_path: string,
	noise_threshold_pct: f64 = 2.0,
	color_output := true,
	fail_on_regression := false,
	fail_on_alloc_regression := false,
) -> (
	passed: bool,
	err: Report_Error,
) {
	baseline := read_json_report(old_path, context.temp_allocator) or_return
	candidate := read_json_report(new_path, context.temp_allocator) or_return

	p := _palette(color_output)
	sb := strings.builder_make(context.temp_allocator)
	out := strings.to_writer(&sb)
	fmt.wprintf(
		out,
		"\n%sobench compare:%s %s%s vs %s (threshold=%.1f%%)%s\n",
		p.bold,
		p.reset,
		p.dim,
		old_path,
		new_path,
		noise_threshold_pct,
		p.reset,
	)
	summary := write_comparison(out, baseline, candidate, noise_threshold_pct, color_output)
	fmt.wprintln(out)
	_, _ = os.write_string(os.stdout, strings.to_string(sb))

	failed :=
		summary.regressions > 0 ||
		summary.errored > 0 ||
		summary.build_mismatch ||
		summary.alloc_counting_mismatch
	alloc_failed := summary.alloc_regressions > 0
	return !(fail_on_regression && failed) && !(fail_on_alloc_regression && alloc_failed), nil
}
