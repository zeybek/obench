package obench

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
	matched:           int,
	improvements:      int,
	regressions:       int,
	unchanged:         int,
	only_in_baseline:  int,
	only_in_candidate: int,
	// Benchmarks that worked in the baseline but failed in the candidate.
	errored:           int,
	geomean_delta_pct: f64,
}

@(private = "file")
_match_key :: proc(e: Export_Entry) -> string {
	return fmt.tprintf("%s\x00%s", e.suite_name, e.full_name)
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

	baseline_by_key := make(map[string]Export_Entry, context.temp_allocator)
	for &e in baseline.benchmarks {
		if e.error == "" {
			baseline_by_key[_match_key(e)] = e
		}
	}
	several_suites := _has_several_suites(candidate.benchmarks)

	if baseline.os != candidate.os || baseline.arch != candidate.arch {
		fmt.wprintf(
			w,
			"%swarning:%s comparing %s/%s against %s/%s\n",
			p.red,
			p.reset,
			baseline.os,
			baseline.arch,
			candidate.os,
			candidate.arch,
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
				table.row(tbl)
				row := table.last_row(tbl)
				name :=
					several_suites ? fmt.tprintf("%s/%s", e.suite_name, e.full_name) : e.full_name
				_set_cell(tbl, row, 0, name, .Left)
				_set_cell(tbl, row, 1, format_duration_ns(old_e.p50_ns))
				_set_cell(tbl, row, 2, "-")
				_set_cell(tbl, row, 3, fmt.tprintf("%sERROR%s", p.red, p.reset))
				_set_cell(tbl, row, 4, "-")
				_set_cell(tbl, row, 5, e.error, .Left)
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

		if ratio := 1.0 + diff.delta_median_pct / 100.0; diff.has_baseline && ratio > 0 {
			ratio_log_sum += math.ln(ratio)
			ratio_count += 1
		}

		delta_color, verdict := p.dim, "~"
		switch {
		case diff.is_improvement:
			delta_color, verdict = p.green, "faster"
			summary.improvements += 1
		case diff.is_regression:
			delta_color, verdict = p.red, "SLOWER"
			summary.regressions += 1
		case:
			summary.unchanged += 1
		}

		bytes_str := "0 B → 0 B"
		if old_st.alloc_bytes_per_op > 0 || new_st.alloc_bytes_per_op > 0 {
			bytes_str = fmt.tprintf(
				"%s → %s (%+.1f%%)",
				format_bytes(old_st.alloc_bytes_per_op),
				format_bytes(new_st.alloc_bytes_per_op),
				diff.delta_bytes_pct,
			)
		}

		table.row(tbl)
		row := table.last_row(tbl)
		_set_cell(
			tbl,
			row,
			0,
			several_suites ? fmt.tprintf("%s/%s", e.suite_name, e.full_name) : e.full_name,
			.Left,
		)
		_set_cell(tbl, row, 1, format_duration_ns(old_st.p50_ns))
		_set_cell(tbl, row, 2, format_duration_ns(new_st.p50_ns))
		_set_cell(
			tbl,
			row,
			3,
			fmt.tprintf("%s%+.2f%% %s%s", delta_color, diff.delta_median_pct, verdict, p.reset),
		)
		significance: string
		switch {
		case diff.rank_test:
			significance = fmt.tprintf("p=%.4f", diff.p_value)
		case math.is_inf(diff.welch_t, 0):
			significance = "|t|=inf"
		case:
			significance = fmt.tprintf("|t|=%.2f", abs(diff.welch_t))
		}
		_set_cell(tbl, row, 4, significance)
		_set_cell(tbl, row, 5, bytes_str, .Left)
	}

	for key in baseline_by_key {
		if key not_in seen {
			summary.only_in_baseline += 1
		}
	}
	if ratio_count > 0 {
		summary.geomean_delta_pct = (math.exp(ratio_log_sum / f64(ratio_count)) - 1.0) * 100.0
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
Compares two saved JSON reports in `benchstat` style and prints the result to stdout
(see `write_comparison`).

`passed` is `false` only when `fail_on_regression` is set and either something regressed or a
benchmark that worked in the baseline failed in the candidate. Benchmarks missing from one
side are listed but don't fail the comparison (a candidate run may use a filter).
*/
@(require_results)
compare_baseline_files :: proc(
	old_path: string,
	new_path: string,
	noise_threshold_pct: f64 = 2.0,
	color_output := true,
	fail_on_regression := false,
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

	return !(fail_on_regression && (summary.regressions > 0 || summary.errored > 0)), nil
}
