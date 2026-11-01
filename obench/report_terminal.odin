package obench

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:text/table"

@(private = "file")
ANSI_RESET :: "\x1b[0m"
@(private = "file")
ANSI_BOLD :: "\x1b[1m"
@(private = "file")
ANSI_DIM :: "\x1b[2m"
@(private = "file")
ANSI_RED :: "\x1b[31m"
@(private = "file")
ANSI_GREEN :: "\x1b[32m"
@(private = "file")
ANSI_YELLOW :: "\x1b[33m"
@(private = "file")
ANSI_CYAN :: "\x1b[36m"
@(private = "file")
ANSI_MAGENTA :: "\x1b[35m"

/*
Formats a duration in nanoseconds into a compact human-readable string (`ps`, `ns`, `us`, `ms`, `s`).
*/
@(require_results)
format_duration_ns :: proc(ns: f64, allocator := context.temp_allocator) -> string {
	if ns <= 0 {
		return fmt.aprintf("0.00 ns", allocator = allocator)
	}
	if ns < 1.0 {
		return fmt.aprintf("%.1f ps", ns * 1000.0, allocator = allocator)
	}
	if ns < 1000.0 {
		return fmt.aprintf("%.2f ns", ns, allocator = allocator)
	}
	if ns < 1_000_000.0 {
		return fmt.aprintf("%.2f us", ns / 1000.0, allocator = allocator)
	}
	if ns < 1_000_000_000.0 {
		return fmt.aprintf("%.2f ms", ns / 1_000_000.0, allocator = allocator)
	}
	return fmt.aprintf("%.3f s", ns / 1_000_000_000.0, allocator = allocator)
}

/*
Formats a cycle count into a compact string (`c`, `Kc`, `Mc`).
*/
@(require_results)
format_cycles :: proc(cyc: f64, allocator := context.temp_allocator) -> string {
	if cyc <= 0 {
		return fmt.aprintf("-", allocator = allocator)
	}
	if cyc < 1000.0 {
		return fmt.aprintf("%.1f c", cyc, allocator = allocator)
	}
	if cyc < 1_000_000.0 {
		return fmt.aprintf("%.2f Kc", cyc / 1000.0, allocator = allocator)
	}
	return fmt.aprintf("%.2f Mc", cyc / 1_000_000.0, allocator = allocator)
}

/*
Formats a byte count per operation into a compact string (`B`, `KiB`, `MiB`).
*/
@(require_results)
format_bytes :: proc(b: f64, allocator := context.temp_allocator) -> string {
	if b <= 0.005 {
		return fmt.aprintf("0 B", allocator = allocator)
	}
	if b < 1024.0 {
		return fmt.aprintf("%.0f B", b, allocator = allocator)
	}
	if b < 1024.0 * 1024.0 {
		return fmt.aprintf("%.2f KiB", b / 1024.0, allocator = allocator)
	}
	return fmt.aprintf("%.2f MiB", b / (1024.0 * 1024.0), allocator = allocator)
}

/*
Formats an 8-bin histogram into an 8-character Unicode sparkline.
*/
@(require_results)
format_sparkline :: proc(hist: [HISTOGRAM_BINS]u8, allocator := context.temp_allocator) -> string {
	bars := [8]rune{' ', '▁', '▂', '▃', '▄', '▅', '▆', '█'}
	sb := strings.builder_make(allocator)
	for level in hist {
		strings.write_rune(&sb, bars[clamp(int(level), 0, 7)])
	}
	return strings.to_string(sb)
}

/*
Formats throughput (`MiB/s`, `GiB/s`, or `Mitem/s`) if the benchmark set bytes or items per
operation. Returns `""` otherwise.
*/
@(require_results)
format_throughput :: proc(st: Stats, allocator := context.temp_allocator) -> string {
	if st.mb_per_sec > 0 {
		if st.mb_per_sec >= 1024.0 {
			return fmt.aprintf("%.2f GiB/s", st.mb_per_sec / 1024.0, allocator = allocator)
		}
		return fmt.aprintf("%.1f MiB/s", st.mb_per_sec, allocator = allocator)
	}
	if st.items_per_sec > 0 {
		if st.items_per_sec >= 1_000_000_000.0 {
			return fmt.aprintf(
				"%.2f Gitem/s",
				st.items_per_sec / 1_000_000_000.0,
				allocator = allocator,
			)
		}
		if st.items_per_sec >= 1_000_000.0 {
			return fmt.aprintf(
				"%.2f Mitem/s",
				st.items_per_sec / 1_000_000.0,
				allocator = allocator,
			)
		}
		if st.items_per_sec >= 1000.0 {
			return fmt.aprintf("%.1f Kitem/s", st.items_per_sec / 1000.0, allocator = allocator)
		}
		return fmt.aprintf("%.0f item/s", st.items_per_sec, allocator = allocator)
	}
	return ""
}

/*
Human-readable description of a `Bench_Error`.
*/
@(require_results)
bench_error_message :: proc "contextless" (e: Bench_Error) -> string {
	switch e {
	case .None:
		return ""
	case .No_Measurement:
		return "benchmark never called obench.step, iter_batched, or run_parallel"
	case .Loop_Exited_Early:
		return "the `for obench.step(b)` loop was left before the batch finished (break/return)"
	case .Measured_Twice:
		return(
			"the benchmark measured more than once (iter_batched, iter_with_large_drop, or run_parallel after another measurement)" \
		)
	}
	return "unknown error"
}

// `table.unicode_width_proc` that skips ANSI escape sequences, so colored cells line up.
@(private)
_ansi_width_proc :: proc(text: string) -> int {
	if strings.index_byte(text, 0x1b) < 0 {
		return table.unicode_width_proc(text)
	}
	visible := strings.builder_make(context.temp_allocator)
	in_escape := false
	for i in 0 ..< len(text) {
		c := text[i]
		switch {
		case in_escape:
			in_escape = !((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))
		case c == 0x1b:
			in_escape = true
		case:
			strings.write_byte(&visible, c)
		}
	}
	return table.unicode_width_proc(strings.to_string(visible))
}

// A `text/table` table whose cell text is formatted into its own arena: `table.destroy`
// calls `free_all` on the format allocator, which must never be the caller's temp allocator.
@(private)
_Report_Table :: struct {
	tbl:   table.Table,
	arena: runtime.Arena,
}

@(private)
_report_table_init :: proc(rt: ^_Report_Table) -> ^table.Table {
	rt.arena = runtime.Arena {
		backing_allocator = context.allocator,
	}
	table.init(&rt.tbl, runtime.arena_allocator(&rt.arena), context.allocator)
	return &rt.tbl
}

@(private)
_report_table_destroy :: proc(rt: ^_Report_Table) {
	table.destroy(&rt.tbl)
	runtime.arena_destroy(&rt.arena)
}

// Writes one row of a built table with `sep` between cells and no outer border.
@(private)
_write_table_row :: proc(w: io.Writer, tbl: ^table.Table, row: int, sep: string) {
	for col in 0 ..< tbl.nr_cols {
		if col > 0 {
			io.write_string(w, sep)
		}
		if col == tbl.nr_cols - 1 && table.get_cell(tbl, row, col).alignment == .Left {
			// Don't pad the last column with trailing spaces.
			io.write_string(w, table.get_cell(tbl, row, col).text)
		} else {
			table.write_table_cell(w, tbl, row, col)
		}
	}
	io.write_byte(w, '\n')
}

// Total width of a built table drawn with a separator of `sep_width` columns.
@(private)
_table_width :: proc(tbl: ^table.Table, sep_width: int) -> int {
	width := 0
	for col_width in tbl.colw {
		width += col_width
	}
	return width + sep_width * max(tbl.nr_cols - 1, 0)
}

@(private)
_set_cell :: proc(
	tbl: ^table.Table,
	row, col: int,
	text: string,
	alignment := table.Cell_Alignment.Right,
) {
	table.set_cell_value_and_alignment(tbl, row, col, text, alignment)
}

@(private = "file")
_entry_label :: proc(r: Result) -> string {
	if r.has_param && r.has_threads {
		return fmt.tprintf("%s[%d]/t%d", r.name, r.param, r.threads)
	}
	if r.has_param {
		return fmt.tprintf("%s[%d]", r.name, r.param)
	}
	if r.has_threads {
		return fmt.tprintf("%s/t%d", r.name, r.threads)
	}
	return r.name
}

@(private)
_Palette :: struct {
	bold, dim, reset, green, red, yellow, cyan, magenta: string,
}

@(private)
_palette :: proc(color: bool) -> _Palette {
	if !color {
		return {}
	}
	return _Palette {
		bold = ANSI_BOLD,
		dim = ANSI_DIM,
		reset = ANSI_RESET,
		green = ANSI_GREEN,
		red = ANSI_RED,
		yellow = ANSI_YELLOW,
		cyan = ANSI_CYAN,
		magenta = ANSI_MAGENTA,
	}
}

@(private = "file")
_alloc_cell :: proc(st: Stats) -> string {
	if st.allocs_per_op < 0.005 && st.temp_allocs_per_op < 0.005 {
		return "0 allocs"
	}
	if st.allocs_per_op >= 0.005 {
		return fmt.tprintf("%.1f / %s", st.allocs_per_op, format_bytes(st.alloc_bytes_per_op))
	}
	return fmt.tprintf(
		"0 (tmp %.1f/%s)",
		st.temp_allocs_per_op,
		format_bytes(st.temp_bytes_per_op),
	)
}

@(private = "file")
_notes_cell :: proc(s: ^Suite, r: Result, p: _Palette) -> string {
	sb := strings.builder_make(context.temp_allocator)
	if s.config.show_histogram {
		fmt.sbprintf(&sb, "%s%s%s ", p.dim, format_sparkline(r.stats.histogram), p.reset)
	}
	if tput := format_throughput(r.stats); tput != "" {
		fmt.sbprintf(&sb, "%s%s%s ", p.magenta, tput, p.reset)
	}
	for i in 0 ..< r.stats.custom_metrics_count {
		cm := r.stats.custom_metrics[i]
		fmt.sbprintf(&sb, "%s%.2f %s%s ", p.cyan, cm.value, cm.unit, p.reset)
	}

	ratio := r.speedup_vs_first
	if ratio > 0 && (ratio > 1.03 || ratio < 0.97) {
		switch {
		case !r.speedup_significant:
			fmt.sbprintf(
				&sb,
				"%s~%.2fx (noise)%s ",
				p.dim,
				ratio >= 1 ? ratio : 1.0 / ratio,
				p.reset,
			)
		case ratio > 1:
			fmt.sbprintf(&sb, "%s%.2fx faster%s ", p.green, ratio, p.reset)
		case:
			fmt.sbprintf(&sb, "%s%.2fx slower%s ", p.yellow, 1.0 / ratio, p.reset)
		}
	}

	if r.diff.has_baseline {
		switch {
		case r.diff.is_improvement:
			fmt.sbprintf(&sb, "%s[%.1f%%]%s ", p.green, r.diff.delta_median_pct, p.reset)
		case r.diff.is_regression:
			fmt.sbprintf(&sb, "%s[+%.1f%%]%s ", p.red, r.diff.delta_median_pct, p.reset)
		case:
			fmt.sbprintf(&sb, "%s[%+.1f%% ~]%s ", p.dim, r.diff.delta_median_pct, p.reset)
		}
	}

	// A sample window within 100 ticks of the clock is quantized by at least 1%.
	window_ns := r.stats.p50_ns * f64(max(r.stats.batch_size, 1))
	if s.clock.resolution_ns > 0 && window_ns > 0 && window_ns < 100 * s.clock.resolution_ns {
		fmt.sbprintf(&sb, "%s[near timer resolution]%s ", p.yellow, p.reset)
	}

	if r.zero_alloc_failed {
		fmt.sbprintf(&sb, "%s[FAIL: @zero_alloc]%s", p.red, p.reset)
	}
	return strings.trim_right_space(strings.to_string(sb))
}

/*
Writes the terminal report (a tree of groups with timings, allocations, sparklines, Big-O
estimates, and the suite summary) to `w`. Formatting uses `context.temp_allocator`.
*/
write_terminal_report :: proc(w: io.Writer, s: ^Suite) {
	p := _palette(s.config.color_output)
	show_cycles := s.clock.has_cycle_counter

	fmt.wprintf(
		w,
		"\n%sobench:%s %s%s (%s/%s, -o:%v, timer overhead %.1f ns, resolution %.1f ns)%s\n",
		p.bold,
		p.reset,
		p.dim,
		s.name,
		ODIN_OS_STRING,
		ODIN_ARCH_STRING,
		ODIN_OPTIMIZATION_MODE,
		s.clock.overhead_ns,
		s.clock.resolution_ns,
		p.reset,
	)
	when ODIN_OPTIMIZATION_MODE == .None || ODIN_OPTIMIZATION_MODE == .Minimal {
		fmt.wprintf(
			w,
			"%swarning:%s compiled with -o:%v; pass %s-o:speed%s for realistic benchmark timings.\n",
			p.yellow,
			p.reset,
			ODIN_OPTIMIZATION_MODE,
			p.bold,
			p.reset,
		)
	}
	when ODIN_DEBUG {
		fmt.wprintf(
			w,
			"%swarning:%s compiled with -debug; timings may not reflect release builds.\n",
			p.yellow,
			p.reset,
		)
	}

	if len(s.results) == 0 {
		fmt.wprintln(w, "No benchmarks matched the filter.")
		return
	}

	rt: _Report_Table
	tbl := _report_table_init(&rt)
	defer _report_table_destroy(&rt)

	// Cells are set one at a time: `set_cell_value*` reads its `any` argument during the
	// call, so no `any` outlives the value it points to.
	if show_cycles {
		table.header(
			tbl,
			"benchmark",
			"fastest",
			"median(p50)",
			"p99",
			"cycles",
			"allocs / bytes",
			"distribution & notes",
		)
	} else {
		table.header(
			tbl,
			"benchmark",
			"fastest",
			"median(p50)",
			"p99",
			"allocs / bytes",
			"distribution & notes",
		)
	}
	notes_col := tbl.nr_cols - 1
	for col in 1 ..< notes_col {
		table.set_cell_alignment(tbl, table.header_row(tbl), col, .Right)
	}

	for &r, idx in s.results {
		is_last_in_group :=
			idx + 1 >= len(s.results) || s.results[idx + 1].group_name != r.group_name
		table.row(tbl)
		row := table.last_row(tbl)
		_set_cell(
			tbl,
			row,
			0,
			fmt.tprintf(" %s %s", is_last_in_group ? "╰─" : "├─", _entry_label(r)),
			.Left,
		)
		if r.error != .None {
			// The numeric columns stay empty and the message goes in the notes column.
			_set_cell(
				tbl,
				row,
				notes_col,
				fmt.tprintf("%sERROR: %s%s", p.red, bench_error_message(r.error), p.reset),
				.Left,
			)
			continue
		}
		col := 1
		_set_cell(tbl, row, col, format_duration_ns(r.stats.min_ns))
		col += 1
		_set_cell(
			tbl,
			row,
			col,
			fmt.tprintf("%s%s%s", p.bold, format_duration_ns(r.stats.p50_ns), p.reset),
		)
		col += 1
		_set_cell(tbl, row, col, format_duration_ns(r.stats.p99_ns))
		col += 1
		if show_cycles {
			_set_cell(tbl, row, col, format_cycles(r.stats.median_cycles))
			col += 1
		}
		_set_cell(tbl, row, col, _alloc_cell(r.stats))
		_set_cell(tbl, row, notes_col, _notes_cell(s, r, p), .Left)
	}

	SEP :: " │ "
	table.build(tbl, _ansi_width_proc)
	rule := strings.repeat("─", _table_width(tbl, len(" | ")), context.temp_allocator)

	fmt.wprintf(w, "%s%s%s\n", p.dim, rule, p.reset)
	io.write_string(w, p.bold)
	_write_table_row(w, tbl, table.header_row(tbl), SEP)
	io.write_string(w, p.reset)
	fmt.wprintf(w, "%s%s%s\n", p.dim, rule, p.reset)

	current_group := ""
	for &r, idx in s.results {
		if r.group_name != current_group {
			current_group = r.group_name
			if current_group != "default" {
				fmt.wprintf(w, "%s%s%s\n", p.cyan, current_group, p.reset)
			}
		}
		_write_table_row(w, tbl, idx + 1, SEP)

		if r.zero_alloc_failed {
			fmt.wprintf(
				w,
				"   %s╰─ zero-alloc violation:%s %d bytes allocated at %s(%d:%d) in `%s`\n",
				p.red,
				p.reset,
				r.violation_size,
				r.violation_loc.file_path,
				r.violation_loc.line,
				r.violation_loc.column,
				r.violation_loc.procedure,
			)
		}

		is_last_in_group :=
			idx + 1 >= len(s.results) || s.results[idx + 1].group_name != current_group
		if is_last_in_group {
			_write_group_complexities(w, s, current_group, p)
		}
	}
	fmt.wprintf(w, "%s%s%s\n", p.dim, rule, p.reset)

	_write_summary(w, s, p)
}

@(private = "file")
_write_group_complexities :: proc(w: io.Writer, s: ^Suite, group_name: string, p: _Palette) {
	rt: _Report_Table
	tbl := _report_table_init(&rt)
	defer _report_table_destroy(&rt)

	for est in s.complexities {
		if est.group_name != group_name {
			continue
		}
		table.row_of_values(
			tbl,
			fmt.tprintf(
				"   %s∷ complexity%s %s%s%s",
				p.dim,
				p.reset,
				p.cyan,
				est.bench_name,
				p.reset,
			),
			fmt.tprintf("→ %s%s%s", p.bold, complexity_string(est.best_class), p.reset),
			fmt.tprintf(
				"%s(R²=%.3f, NRMSE=%.1f%%)%s",
				p.dim,
				est.r_squared,
				est.nrmse * 100.0,
				p.reset,
			),
		)
	}
	if tbl.nr_rows == 0 {
		return
	}
	table.build(tbl, _ansi_width_proc)
	for row in 0 ..< tbl.nr_rows {
		_write_table_row(w, tbl, row, " ")
	}
}

@(private = "file")
_write_summary :: proc(w: io.Writer, s: ^Suite, p: _Palette) {
	geomean_str := format_duration_ns(s.summary.geomean_ns)
	diff_summary := ""
	if s.summary.has_baseline_diff {
		diff_color := p.dim
		if s.summary.geomean_delta_pct < -0.5 {
			diff_color = p.green
		} else if s.summary.geomean_delta_pct > 0.5 {
			diff_color = p.red
		}
		diff_summary = fmt.tprintf(
			" │ baseline geomean: %s%+.2f%%%s (%d faster, %d slower, %d unchanged)",
			diff_color,
			s.summary.geomean_delta_pct,
			p.reset,
			s.summary.improvements,
			s.summary.regressions,
			s.summary.unchanged,
		)
	}

	failures := suite_failure_count(s)
	if failures > 0 {
		fmt.wprintf(
			w,
			"%sFAIL:%s %d benchmark(s) │ geomean: %s%s%s (%d errors, %d @zero_alloc failed, %d regressions, %d file errors)%s\n\n",
			p.red,
			p.reset,
			len(s.results),
			p.bold,
			geomean_str,
			p.reset,
			s.failed_errors,
			s.failed_zero_alloc,
			s.failed_regressions,
			s.failed_io,
			diff_summary,
		)
	} else {
		fmt.wprintf(
			w,
			"%sPASS:%s %d benchmark(s) completed │ geomean: %s%s%s%s\n\n",
			p.green,
			p.reset,
			len(s.results),
			p.bold,
			geomean_str,
			p.reset,
			diff_summary,
		)
	}
}

/*
Prints the terminal report to stdout with a single write. See `write_terminal_report`.
*/
print_terminal_report :: proc(s: ^Suite) {
	sb := strings.builder_make(context.temp_allocator)
	write_terminal_report(strings.to_writer(&sb), s)
	_, _ = os.write_string(os.stdout, strings.to_string(sb))
}
