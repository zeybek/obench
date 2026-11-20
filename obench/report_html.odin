package obench

import "core:fmt"
import "core:io"
import "core:math"
import "core:slice"
import "core:strings"

/*
Writes `doc` as one self-contained HTML page: no scripts and nothing loaded from elsewhere, so
it can be attached to a CI run or opened from disk. Every benchmark gets its times and
allocations and a histogram of its samples in inline SVG, a group with `@params` gets a chart
of time against N with its fitted complexity, and `baseline`, when given, is drawn over the
histograms and shown as a change of the median, colored only when the change passes the test
`compare` uses (see `compare_baseline`). Everything is allocated with `context.temp_allocator`.
*/
write_html_report :: proc(
	w: io.Writer,
	doc: Export_Document,
	baseline: Maybe(Export_Document) = nil,
) {
	_, with_baseline := baseline.?
	threshold_pct := doc.config.threshold_pct if doc.config.threshold_pct > 0 else 2.0
	base_by_key := make(map[string]Export_Entry, context.temp_allocator)
	if b, ok := baseline.?; ok {
		for e in b.benchmarks {
			if e.error == "" {
				base_by_key[fmt.tprintf("%s\x00%s", e.suite_name, e.full_name)] = e
			}
		}
	}

	io.write_string(w, _HTML_HEAD)
	fmt.wprintf(w, "<title>obench: %s</title>\n", _html(doc.suite_name))
	io.write_string(w, "</head>\n<body>\n<header>\n<h1>obench report</h1>\n<p class=\"meta\">")
	fmt.wprintf(
		w,
		"%s/%s · <code>-o:%s</code> · Odin %s · obench %s",
		_html(doc.os),
		_html(doc.arch),
		_html(doc.optimization),
		_html(doc.odin_version),
		_html(doc.obench_version),
	)
	if doc.machine.cpu != "" {
		fmt.wprintf(w, " · %s", _html(doc.machine.cpu))
	}
	if doc.machine.label != "" {
		fmt.wprintf(w, " (%s)", _html(doc.machine.label))
	}
	if doc.git.commit != "" {
		fmt.wprintf(
			w,
			" · commit <code>%s</code>",
			_html(doc.git.commit[:min(len(doc.git.commit), 12)]),
		)
	}
	if doc.created_at != "" {
		fmt.wprintf(w, " · %s", _html(doc.created_at))
	}
	if doc.clock.resolution_ns > 0 {
		fmt.wprintf(
			w,
			" · timer overhead %.1f ns, resolution %.1f ns",
			doc.clock.overhead_ns,
			doc.clock.resolution_ns,
		)
	}
	io.write_string(w, "</p>\n")
	if with_baseline {
		io.write_string(
			w,
			"<p class=\"legend\"><span class=\"swatch current\"></span> this run <span class=\"swatch baseline\"></span> baseline</p>\n",
		)
	}
	io.write_string(w, "</header>\n<main>\n")

	// Suites in the order they first appear.
	suites := make([dynamic]string, context.temp_allocator)
	for e in doc.benchmarks {
		if !slice.contains(suites[:], e.suite_name) {
			append(&suites, e.suite_name)
		}
	}
	for suite in suites {
		fmt.wprintf(w, "<section>\n<h2>%s</h2>\n<table>\n<thead><tr>", _html(suite))
		io.write_string(
			w,
			"<th>benchmark</th><th>fastest</th><th>median</th><th>p99</th><th>allocs / op</th><th>bytes / op</th>",
		)
		if with_baseline {
			io.write_string(w, "<th>vs baseline</th>")
		}
		io.write_string(w, "<th>distribution</th></tr></thead>\n<tbody>\n")
		for e in doc.benchmarks {
			if e.suite_name != suite {
				continue
			}
			base, has_base := base_by_key[fmt.tprintf("%s\x00%s", e.suite_name, e.full_name)]
			_html_row(w, e, base, has_base, with_baseline, threshold_pct)
		}
		io.write_string(w, "</tbody>\n</table>\n")
		for c in doc.complexities {
			if c.suite_name == suite {
				_html_complexity(w, doc, c)
			}
		}
		io.write_string(w, "</section>\n")
	}
	io.write_string(w, "</main>\n</body>\n</html>\n")
}

@(private = "file")
_HTML_HEAD :: `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root { --bg: #ffffff; --fg: #1f2328; --muted: #59636e; --line: #d1d9e0; --current: #0969da; --baseline: #bf8700; --bad: #cf222e; --good: #1a7f37; }
@media (prefers-color-scheme: dark) {
  :root { --bg: #0d1117; --fg: #e6edf3; --muted: #9198a1; --line: #3d444d; --current: #4493f8; --baseline: #d29922; --bad: #f85149; --good: #3fb950; }
}
body { background: var(--bg); color: var(--fg); font: 14px/1.5 system-ui, sans-serif; margin: 0 auto; max-width: 1100px; padding: 16px; }
h1 { font-size: 20px; margin: 0 0 4px; }
h2 { font-size: 16px; margin: 28px 0 8px; }
.meta, .legend, .note { color: var(--muted); margin: 0; }
code { font: 12px ui-monospace, monospace; }
table { border-collapse: collapse; width: 100%; }
th, td { border-bottom: 1px solid var(--line); padding: 4px 8px; text-align: right; white-space: nowrap; }
th:first-child, td:first-child { text-align: left; white-space: normal; }
td.error { color: var(--bad); text-align: left; }
.slower { color: var(--bad); }
.faster { color: var(--good); }
.swatch { display: inline-block; height: 10px; width: 10px; }
.swatch.current { background: var(--current); }
.swatch.baseline { background: var(--baseline); }
rect.current { fill: var(--current); }
path.baseline { fill: none; stroke: var(--baseline); stroke-width: 1.5; }
.chart { margin: 12px 0; }
.chart text { fill: var(--muted); font: 11px system-ui, sans-serif; }
.chart .axis { fill: none; stroke: var(--line); }
.chart .fit { fill: none; stroke: var(--baseline); stroke-width: 1.5; }
.chart circle { fill: var(--current); }
@media (max-width: 700px) { td:nth-child(2), th:nth-child(2), td:nth-child(4), th:nth-child(4) { display: none; } }
</style>
`

// Text for HTML content and attributes.
@(private = "file")
_html :: proc(s: string) -> string {
	out, _ := strings.replace_all(s, "&", "&amp;", context.temp_allocator)
	out, _ = strings.replace_all(out, "<", "&lt;", context.temp_allocator)
	out, _ = strings.replace_all(out, ">", "&gt;", context.temp_allocator)
	out, _ = strings.replace_all(out, `"`, "&quot;", context.temp_allocator)
	return out
}

@(private = "file")
_html_row :: proc(
	w: io.Writer,
	e: Export_Entry,
	base: Export_Entry,
	has_base: bool,
	with_baseline: bool,
	threshold_pct: f64,
) {
	fmt.wprintf(w, "<tr class=\"bench\"><td>%s</td>", _html(e.full_name))
	if e.error != "" {
		cols := 6 if with_baseline else 5
		fmt.wprintf(w, "<td class=\"error\" colspan=\"%d\">%s</td></tr>\n", cols, _html(e.error))
		return
	}
	fmt.wprintf(
		w,
		"<td>%s</td><td>%s</td><td>%s</td><td>%.1f</td><td>%s</td>",
		format_duration_ns(e.min_ns),
		format_duration_ns(e.p50_ns),
		format_duration_ns(e.p99_ns),
		e.allocs_per_op,
		format_bytes(e.alloc_bytes_per_op),
	)
	if with_baseline {
		if has_base && base.p50_ns > 0 {
			// Colored only when the change passes the same test as `compare`.
			diff := compare_baseline(
				_export_entry_stats(e),
				_export_entry_stats(base),
				threshold_pct,
			)
			switch {
			case diff.is_regression:
				fmt.wprintf(w, "<td class=\"slower\">%+.1f%%</td>", diff.delta_median_pct)
			case diff.is_improvement:
				fmt.wprintf(w, "<td class=\"faster\">%+.1f%%</td>", diff.delta_median_pct)
			case:
				fmt.wprintf(w, "<td>%+.1f%% ~</td>", diff.delta_median_pct)
			}
		} else {
			io.write_string(w, "<td>-</td>")
		}
	}
	io.write_string(w, "<td>")
	_html_histogram(w, e, base, has_base)
	io.write_string(w, "</td></tr>\n")
}

@(private = "file")
HTML_HISTOGRAM_BINS :: 24

@(private = "file")
_html_bin_counts :: proc(
	samples: []f64,
	lo, hi: f64,
) -> (
	bins: [HTML_HISTOGRAM_BINS]int,
	peak: int,
) {
	for v in samples {
		i := int((v - lo) / (hi - lo) * HTML_HISTOGRAM_BINS)
		if i < 0 || i > HTML_HISTOGRAM_BINS {
			continue // beyond p99
		}
		i = min(i, HTML_HISTOGRAM_BINS - 1)
		bins[i] += 1
		peak = max(peak, bins[i])
	}
	return
}

// The samples between the fastest and p99 as bars, with the baseline's samples, when there
// are any, drawn on the same scale as an outline.
@(private = "file")
_html_histogram :: proc(w: io.Writer, e: Export_Entry, base: Export_Entry, has_base: bool) {
	WIDTH :: 160
	HEIGHT :: 28
	if len(e.samples_ns) == 0 {
		return
	}
	base_drawn := has_base && len(base.samples_ns) > 0
	lo, hi := e.min_ns, e.p99_ns
	if base_drawn {
		lo, hi = min(lo, base.min_ns), max(hi, base.p99_ns)
	}
	if hi <= lo {
		hi = lo + 1
	}
	bins, peak := _html_bin_counts(e.samples_ns, lo, hi)
	base_bins: [HTML_HISTOGRAM_BINS]int
	base_peak := 0
	if base_drawn {
		base_bins, base_peak = _html_bin_counts(base.samples_ns, lo, hi)
	}
	scale := max(peak, base_peak, 1)
	bar_w := f64(WIDTH) / HTML_HISTOGRAM_BINS
	fmt.wprintf(
		w,
		"<svg width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\" role=\"img\" aria-label=\"distribution of %d samples\">",
		WIDTH,
		HEIGHT,
		WIDTH,
		HEIGHT,
		len(e.samples_ns),
	)
	for n, i in bins {
		if n == 0 {
			continue
		}
		h := f64(HEIGHT) * f64(n) / f64(scale)
		fmt.wprintf(
			w,
			"<rect class=\"current\" x=\"%.1f\" y=\"%.1f\" width=\"%.1f\" height=\"%.1f\"/>",
			f64(i) * bar_w,
			f64(HEIGHT) - h,
			bar_w - 1,
			h,
		)
	}
	if base_peak > 0 {
		io.write_string(w, "<path class=\"baseline\" d=\"")
		for n, i in base_bins {
			y := f64(HEIGHT) - f64(HEIGHT) * f64(n) / f64(scale)
			fmt.wprintf(
				w,
				"%s%.1f %.1f H%.1f ",
				i == 0 ? "M" : "L",
				f64(i) * bar_w,
				y,
				f64(i + 1) * bar_w,
			)
		}
		io.write_string(w, "\"/>")
	}
	io.write_string(w, "</svg>")
}

// f(N) of a complexity class written by `complexity_string`.
@(private = "file")
_complexity_basis :: proc(class: string, n: f64) -> f64 {
	safe := max(n, 2)
	switch class {
	case "O(log N)":
		return math.log2(safe)
	case "O(N)":
		return n
	case "O(N log N)":
		return n * math.log2(safe)
	case "O(N^2)":
		return n * n
	case "O(N^3)":
		return n * n * n
	}
	return 1
}

@(private = "file")
HTML_CHART_WIDTH :: 360
@(private = "file")
HTML_CHART_HEIGHT :: 160
@(private = "file")
HTML_CHART_PAD :: 24
// Room left of the y axis for its labels.
@(private = "file")
HTML_CHART_PAD_LEFT :: 72

@(private = "file")
_chart_x :: proc(n, lo, hi: f64) -> f64 {
	return(
		HTML_CHART_PAD_LEFT +
		(math.log10(n) - lo) /
			(hi - lo) *
			(HTML_CHART_WIDTH - HTML_CHART_PAD_LEFT - HTML_CHART_PAD) \
	)
}

@(private = "file")
_chart_y :: proc(t, lo, hi: f64) -> f64 {
	frac := (math.log10(max(t, 1e-12)) - lo) / (hi - lo)
	return HTML_CHART_HEIGHT - HTML_CHART_PAD - frac * (HTML_CHART_HEIGHT - 2 * HTML_CHART_PAD)
}

// The group's median time against N on log scales, with the fitted curve a + c * f(N).
@(private = "file")
_html_complexity :: proc(w: io.Writer, doc: Export_Document, c: Export_Complexity) {
	points := make([dynamic][2]f64, context.temp_allocator)
	for e in doc.benchmarks {
		if e.suite_name == c.suite_name &&
		   e.group_name == c.group_name &&
		   e.name == c.bench_name &&
		   e.has_param &&
		   e.error == "" &&
		   e.param > 0 &&
		   e.p50_ns > 0 {
			append(&points, [2]f64{f64(e.param), e.p50_ns})
		}
	}
	if len(points) < 2 {
		return
	}
	slice.sort_by(points[:], proc(a, b: [2]f64) -> bool {return a[0] < b[0]})
	first, last := points[0][0], points[len(points) - 1][0]
	n_lo, n_hi := math.log10(first), math.log10(last)
	t_lo, t_hi := max(f64), min(f64)
	for p in points {
		t_lo, t_hi = min(t_lo, p[1]), max(t_hi, p[1])
	}
	t_lo, t_hi = math.log10(t_lo), math.log10(t_hi)
	if n_hi <= n_lo {
		n_hi = n_lo + 1
	}
	if t_hi <= t_lo {
		t_hi, t_lo = t_lo + 0.5, t_lo - 0.5
	}

	name := c.group_name != "" ? fmt.tprintf("%s::%s", c.group_name, c.bench_name) : c.bench_name
	fmt.wprintf(
		w,
		"<div class=\"chart\"><p class=\"note\">%s: %s (R² %.3f), median time against N</p>",
		_html(name),
		_html(c.complexity),
		c.r_squared,
	)
	fmt.wprintf(
		w,
		"<svg width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\" role=\"img\" aria-label=\"%s: time against N\">",
		HTML_CHART_WIDTH,
		HTML_CHART_HEIGHT,
		HTML_CHART_WIDTH,
		HTML_CHART_HEIGHT,
		_html(name),
	)
	fmt.wprintf(
		w,
		"<path class=\"axis\" d=\"M%d %d V%d H%d\"/>",
		HTML_CHART_PAD_LEFT - 6,
		HTML_CHART_PAD / 2,
		HTML_CHART_HEIGHT - HTML_CHART_PAD,
		HTML_CHART_WIDTH - HTML_CHART_PAD / 2,
	)
	io.write_string(w, "<path class=\"fit\" d=\"")
	STEPS :: 40
	for i in 0 ..= STEPS {
		n := math.pow(10, n_lo + (math.log10(last) - n_lo) * f64(i) / STEPS)
		t := c.intercept + c.coefficient * _complexity_basis(c.complexity, n)
		fmt.wprintf(
			w,
			"%s%.1f %.1f ",
			i == 0 ? "M" : "L",
			_chart_x(n, n_lo, n_hi),
			_chart_y(t, t_lo, t_hi),
		)
	}
	io.write_string(w, "\"/>")
	for p in points {
		fmt.wprintf(
			w,
			"<circle cx=\"%.1f\" cy=\"%.1f\" r=\"3\"/>",
			_chart_x(p[0], n_lo, n_hi),
			_chart_y(p[1], t_lo, t_hi),
		)
	}
	fmt.wprintf(
		w,
		"<text x=\"%d\" y=\"%d\">N = %d</text><text x=\"%d\" y=\"%d\" text-anchor=\"end\">N = %d</text>",
		HTML_CHART_PAD_LEFT,
		HTML_CHART_HEIGHT - HTML_CHART_PAD + 16,
		int(first),
		HTML_CHART_WIDTH - HTML_CHART_PAD / 2,
		HTML_CHART_HEIGHT - HTML_CHART_PAD + 16,
		int(last),
	)
	fmt.wprintf(
		w,
		"<text x=\"%d\" y=\"%d\" text-anchor=\"end\">%s</text><text x=\"%d\" y=\"%d\" text-anchor=\"end\">%s</text></svg></div>\n",
		HTML_CHART_PAD_LEFT - 12,
		HTML_CHART_PAD + 4,
		format_duration_ns(math.pow(10, t_hi)),
		HTML_CHART_PAD_LEFT - 12,
		HTML_CHART_HEIGHT - HTML_CHART_PAD + 4,
		format_duration_ns(math.pow(10, t_lo)),
	)
}

/*
Writes the suite's results to `path` as an HTML page (see `write_html_report`), with the
baseline from `Config.baseline_load_path` drawn over it when that file can be read.
*/
@(require_results)
save_html_report :: proc(s: ^Suite, path: string) -> Report_Error {
	return _save_rendered(path, s, proc(w: io.Writer, data: rawptr) -> Report_Error {
		s := (^Suite)(data)
		baseline: Maybe(Export_Document)
		if s.config.baseline_load_path != "" {
			if b, err := read_json_report(s.config.baseline_load_path, context.temp_allocator);
			   err == nil {
				baseline = b
			}
		}
		write_html_report(w, export_document(s, context.temp_allocator), baseline)
		return nil
	})
}
