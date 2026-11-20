package obench_tests

import obench "../obench"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
_html_config :: proc() -> obench.Config {
	return obench.Config {
		warmup_time = 1 * time.Millisecond,
		min_sample_time = 50 * time.Microsecond,
		max_bench_time = 50 * time.Millisecond,
		sample_count = 10,
		fixed_batch_size = 16,
		reset_temp_per_iter = true,
		untimed_alloc_check = obench.DEFAULT_UNTIMED_ALLOCS,
		noise_threshold_pct = 2.0,
	}
}

@(private = "file")
_html_step :: proc(b: ^obench.Bencher) {
	for obench.step(b) {
		_ = obench.black_box(1)
	}
}

@(test)
test_html_report_of_a_run_is_one_self_contained_page :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	s := obench.suite_create("a <b> & c", _html_config())
	defer obench.suite_destroy(&s)
	obench.bench(&s, "first", _html_step)
	obench.bench(&s, "second", _html_step)
	testing.expect(t, obench.suite_run(&s))

	sb := strings.builder_make(context.temp_allocator)
	obench.write_html_report(
		strings.to_writer(&sb),
		obench.export_document(&s, context.temp_allocator),
	)
	page := strings.to_string(sb)
	testing.expect(t, strings.has_prefix(page, "<!doctype html>"))
	testing.expect(t, strings.has_suffix(page, "</html>\n"))
	testing.expect_value(t, strings.count(page, `<tr class="bench">`), 2)
	testing.expect_value(t, strings.count(page, "<svg"), 2)
	testing.expect(
		t,
		strings.contains(page, "<h2>a &lt;b&gt; &amp; c</h2>"),
		"the suite name is escaped",
	)
	testing.expect(t, !strings.contains(page, "<script"), "no scripts")
	testing.expect(t, !strings.contains(page, "vs baseline"), "no baseline column without one")
}

@(test)
test_html_report_draws_the_baseline_errors_and_complexity :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	samples := make([]f64, 20, context.temp_allocator)
	for &v, i in samples {
		v = 100 + f64(i)
	}
	params := [3]int{16, 256, 4096}
	entries := make([]obench.Export_Entry, 4, context.temp_allocator)
	for &e, i in entries {
		e = obench.Export_Entry {
			suite_name = "s",
			group_name = "grow",
			name       = "append",
			has_param  = true,
			param      = params[min(i, 2)],
			samples    = len(samples),
			min_ns     = 100,
			p50_ns     = 110 * f64(i + 1),
			p99_ns     = 119,
			mean_ns    = 110,
			std_dev_ns = 5,
			samples_ns = samples,
		}
	}
	entries[0].full_name = "grow::append[16]"
	entries[1].full_name = "grow::append[256]"
	entries[2].full_name = "grow::append[4096]"
	entries[3] = {
		suite_name = "s",
		full_name  = "broken",
		error      = "Loop_Exited_Early",
	}
	complexities := []obench.Export_Complexity {
		{
			suite_name = "s",
			group_name = "grow",
			bench_name = "append",
			complexity = "O(N)",
			coefficient = 1,
			intercept = 100,
			r_squared = 0.99,
		},
	}
	doc := obench.Export_Document {
		format_version = obench.REPORT_FORMAT_VERSION,
		suite_name     = "s",
		benchmarks     = entries,
		complexities   = complexities,
	}

	sb := strings.builder_make(context.temp_allocator)
	obench.write_html_report(strings.to_writer(&sb), doc, doc)
	page := strings.to_string(sb)
	testing.expect(t, strings.contains(page, "<th>vs baseline</th>"))
	testing.expect_value(t, strings.count(page, `<path class="baseline"`), 3)
	testing.expect(
		t,
		strings.contains(page, `<td class="error" colspan="6">Loop_Exited_Early</td>`),
		page,
	)
	testing.expect_value(t, strings.count(page, `class="chart"`), 1)
	testing.expect(t, strings.contains(page, "grow::append: O(N)"), page)
	testing.expect(t, strings.contains(page, "+0.0% ~"), "an unchanged benchmark isn't colored")
}

@(test)
test_html_export_path_writes_the_page :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := ".obench_test_report.html"
	defer _ = os.remove(path)
	cfg := _html_config()
	cfg.html_export_path = path
	s := obench.suite_create("html_file", cfg)
	defer obench.suite_destroy(&s)
	obench.bench(&s, "only", _html_step)
	testing.expect(t, obench.suite_run(&s))
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect(t, strings.contains(string(data), `<tr class="bench"><td>only</td>`))
}
