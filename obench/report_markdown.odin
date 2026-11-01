package obench

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:text/table"

// Escapes `|` and backticks so text can sit inside a Markdown table cell.
@(private = "file")
_md_cell :: proc(text: string) -> string {
	if !strings.contains_any(text, "|`") {
		return text
	}
	out, _ := strings.replace_all(text, "|", "\\|", context.temp_allocator)
	out, _ = strings.replace_all(out, "`", "'", context.temp_allocator)
	return out
}

/*
Writes a GitHub-flavored Markdown report to `w`.
*/
@(require_results)
write_markdown_report :: proc(w: io.Writer, s: ^Suite) -> io.Error {
	fmt.wprintf(w, "## Benchmark report: %s\n\n", _md_cell(s.name))
	fmt.wprintf(
		w,
		"- Platform: `%s/%s`\n- Odin: `%s`, `-o:%v`\n- Timer: overhead `%.1f ns`, resolution `%.1f ns`\n- Suite geomean: `%s`\n\n",
		ODIN_OS_STRING,
		ODIN_ARCH_STRING,
		ODIN_VERSION,
		ODIN_OPTIMIZATION_MODE,
		s.clock.overhead_ns,
		s.clock.resolution_ns,
		format_duration_ns(s.summary.geomean_ns),
	)

	rt: _Report_Table
	tbl := _report_table_init(&rt)
	defer _report_table_destroy(&rt)

	table.header(
		tbl,
		"Benchmark",
		"Fastest",
		"Median (p50)",
		"±CI95",
		"p99",
		"Allocs/op",
		"Bytes/op",
		"Notes",
	)
	for col in 1 ..< 7 {
		table.set_cell_alignment(tbl, table.header_row(tbl), col, .Right)
	}

	for &r in s.results {
		table.row(tbl)
		row := table.last_row(tbl)
		_set_cell(tbl, row, 0, fmt.tprintf("`%s`", _md_cell(r.full_name)), .Left)
		if r.error != .None {
			_set_cell(
				tbl,
				row,
				7,
				fmt.tprintf("**error:** %s", bench_error_string(r.error)),
				.Left,
			)
			continue
		}

		notes := strings.builder_make(context.temp_allocator)
		if tput := format_throughput(r.stats); tput != "" {
			fmt.sbprintf(&notes, "%s ", tput)
		}
		for i in 0 ..< r.stats.custom_metrics_count {
			cm := r.stats.custom_metrics[i]
			fmt.sbprintf(&notes, "`%.2f %s` ", cm.value, _md_cell(cm.unit))
		}
		if r.speedup_significant {
			if r.speedup_vs_first > 1 {
				fmt.sbprintf(&notes, "**%.2fx faster** ", r.speedup_vs_first)
			} else if r.speedup_vs_first > 0 {
				fmt.sbprintf(&notes, "%.2fx slower ", 1.0 / r.speedup_vs_first)
			}
		}
		if r.diff.has_baseline {
			fmt.sbprintf(
				&notes,
				"(%+.1f%% vs baseline%s) ",
				r.diff.delta_median_pct,
				r.diff.is_regression ? ", regression" : "",
			)
		}
		if r.zero_alloc_failed {
			strings.write_string(&notes, "**@zero_alloc failed**")
		}

		_set_cell(tbl, row, 1, format_duration_ns(r.stats.min_ns))
		_set_cell(tbl, row, 2, fmt.tprintf("**%s**", format_duration_ns(r.stats.p50_ns)))
		_set_cell(tbl, row, 3, fmt.tprintf("±%s", format_duration_ns(r.stats.ci95_ns)))
		_set_cell(tbl, row, 4, format_duration_ns(r.stats.p99_ns))
		_set_cell(tbl, row, 5, fmt.tprintf("%.2f", r.stats.allocs_per_op))
		_set_cell(tbl, row, 6, format_bytes(r.stats.alloc_bytes_per_op))
		_set_cell(tbl, row, 7, strings.trim_space(strings.to_string(notes)), .Left)
	}
	table.write_markdown_table(w, tbl)

	if len(s.complexities) > 0 {
		io.write_string(w, "\n### Asymptotic Complexity (Big-O)\n\n") or_return

		crt: _Report_Table
		ctbl := _report_table_init(&crt)
		defer _report_table_destroy(&crt)

		table.header(ctbl, "Group", "Benchmark", "Fitted Complexity", "R²", "NRMSE")
		table.set_cell_alignment(ctbl, table.header_row(ctbl), 3, .Right)
		table.set_cell_alignment(ctbl, table.header_row(ctbl), 4, .Right)
		for c in s.complexities {
			table.row(
				ctbl,
				fmt.tprintf("`%s`", _md_cell(c.group_name)),
				fmt.tprintf("`%s`", _md_cell(c.bench_name)),
				fmt.tprintf("**`%s`**", complexity_string(c.best_class)),
				fmt.tprintf("%.4f", c.r_squared),
				fmt.tprintf("%.2f%%", c.nrmse * 100.0),
			)
		}
		table.write_markdown_table(w, ctbl)
	}
	return nil
}

/*
Writes a GitHub-flavored Markdown report to `path`.
*/
@(require_results)
save_markdown_report :: proc(s: ^Suite, path: string) -> Report_Error {
	return _save_rendered(path, s, proc(w: io.Writer, data: rawptr) -> Report_Error {
		return os.Error(write_markdown_report(w, (^Suite)(data)))
	})
}
