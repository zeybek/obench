package obench

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"

/*
Version of the JSON report layout. Bumped whenever the layout changes. Readers accept older
versions; fields that are missing stay zero.

Version 3 added `samples_ns` (every sample's time per operation) to each benchmark and
`intercept` to each complexity fit.
*/
REPORT_FORMAT_VERSION :: 3

/*
Serializable record for a single benchmark in a JSON baseline or export file.
*/
Export_Entry :: struct {
	suite_name:         string `json:"suite_name"`,
	full_name:          string `json:"full_name"`,
	group_name:         string `json:"group_name"`,
	name:               string `json:"name"`,
	param:              int `json:"param"`,
	has_param:          bool `json:"has_param"`,
	threads:            int `json:"threads"`,
	has_threads:        bool `json:"has_threads"`,
	error:              string `json:"error,omitempty"`,
	samples:            int `json:"samples"`,
	batch_size:         int `json:"batch_size"`,
	min_ns:             f64 `json:"min_ns"`,
	p50_ns:             f64 `json:"p50_ns"`,
	p95_ns:             f64 `json:"p95_ns"`,
	p99_ns:             f64 `json:"p99_ns"`,
	max_ns:             f64 `json:"max_ns"`,
	mean_ns:            f64 `json:"mean_ns"`,
	std_dev_ns:         f64 `json:"std_dev_ns"`,
	ci95_ns:            f64 `json:"ci95_ns"`,
	mad_ns:             f64 `json:"mad_ns"`,
	median_cycles:      f64 `json:"median_cycles"`,
	mb_per_sec:         f64 `json:"mb_per_sec"`,
	items_per_sec:      f64 `json:"items_per_sec"`,
	allocs_per_op:      f64 `json:"allocs_per_op"`,
	resizes_per_op:     f64 `json:"resizes_per_op"`,
	alloc_bytes_per_op: f64 `json:"alloc_bytes_per_op"`,
	temp_allocs_per_op: f64 `json:"temp_allocs_per_op"`,
	temp_bytes_per_op:  f64 `json:"temp_bytes_per_op"`,
	custom_metrics:     []Custom_Metric `json:"custom_metrics,omitempty"`,
	samples_ns:         []f64 `json:"samples_ns,omitempty"`,
}

/*
Serializable record for an inferred Big-O complexity fit.
*/
Export_Complexity :: struct {
	suite_name:  string `json:"suite_name"`,
	group_name:  string `json:"group_name"`,
	bench_name:  string `json:"bench_name"`,
	complexity:  string `json:"complexity"`,
	coefficient: f64 `json:"coefficient"`,
	intercept:   f64 `json:"intercept"`,
	r_squared:   f64 `json:"r_squared"`,
	nrmse:       f64 `json:"nrmse"`,
}

/*
Root JSON document written by `--save-baseline` and `--json`. A document produced by the
CLI for several packages contains the benchmarks of every suite; each entry carries its
own `suite_name`.
*/
Export_Document :: struct {
	format_version: int `json:"format_version"`,
	obench_version: string `json:"obench_version"`,
	odin_version:   string `json:"odin_version"`,
	optimization:   string `json:"optimization"`,
	suite_name:     string `json:"suite_name"`,
	os:             string `json:"os"`,
	arch:           string `json:"arch"`,
	geomean_ns:     f64 `json:"geomean_ns"`,
	benchmarks:     []Export_Entry `json:"benchmarks"`,
	complexities:   []Export_Complexity `json:"complexities,omitempty"`,
}

/*
Builds an export document for `s`. Strings point into the suite; only the slices are
allocated with `allocator`.
*/
@(require_results)
export_document :: proc(
	s: ^Suite,
	allocator := context.allocator,
	loc := #caller_location,
) -> Export_Document {
	entries := make([]Export_Entry, len(s.results), allocator, loc)
	for &r, i in s.results {
		entries[i] = Export_Entry {
			suite_name         = s.name,
			full_name          = r.full_name,
			group_name         = r.group_name,
			name               = r.name,
			param              = r.param,
			has_param          = r.has_param,
			threads            = r.threads,
			has_threads        = r.has_threads,
			error              = bench_error_string(r.error),
			samples            = r.stats.samples,
			batch_size         = r.stats.batch_size,
			min_ns             = r.stats.min_ns,
			p50_ns             = r.stats.p50_ns,
			p95_ns             = r.stats.p95_ns,
			p99_ns             = r.stats.p99_ns,
			max_ns             = r.stats.max_ns,
			mean_ns            = r.stats.mean_ns,
			std_dev_ns         = r.stats.std_dev_ns,
			ci95_ns            = r.stats.ci95_ns,
			mad_ns             = r.stats.mad_ns,
			median_cycles      = r.stats.median_cycles,
			mb_per_sec         = r.stats.mb_per_sec,
			items_per_sec      = r.stats.items_per_sec,
			allocs_per_op      = r.stats.allocs_per_op,
			resizes_per_op     = r.stats.resizes_per_op,
			alloc_bytes_per_op = r.stats.alloc_bytes_per_op,
			temp_allocs_per_op = r.stats.temp_allocs_per_op,
			temp_bytes_per_op  = r.stats.temp_bytes_per_op,
			custom_metrics     = r.stats.custom_metrics[:r.stats.custom_metrics_count],
			samples_ns         = r.stats.samples_ns,
		}
	}

	comp_entries := make([]Export_Complexity, len(s.complexities), allocator, loc)
	for c, i in s.complexities {
		comp_entries[i] = Export_Complexity {
			suite_name  = s.name,
			group_name  = c.group_name,
			bench_name  = c.bench_name,
			complexity  = complexity_string(c.best_class),
			coefficient = c.coefficient,
			intercept   = c.intercept,
			r_squared   = c.r_squared,
			nrmse       = c.nrmse,
		}
	}

	return Export_Document {
		format_version = REPORT_FORMAT_VERSION,
		obench_version = VERSION,
		odin_version = ODIN_VERSION,
		optimization = fmt.aprintf("%v", ODIN_OPTIMIZATION_MODE, allocator = allocator),
		suite_name = s.name,
		os = ODIN_OS_STRING,
		arch = ODIN_ARCH_STRING,
		geomean_ns = s.summary.geomean_ns,
		benchmarks = entries,
		complexities = comp_entries,
	}
}

/*
Writes `doc` as indented JSON to `w`. The document is rendered with `allocator` first and
freed after writing.
*/
@(require_results)
write_json_document :: proc(
	w: io.Writer,
	doc: Export_Document,
	allocator := context.allocator,
	loc := #caller_location,
) -> json.Marshal_Error {
	opt := json.Marshal_Options {
		pretty     = true,
		use_spaces = true,
		spaces     = 2,
	}
	// `json.marshal` rather than `json.marshal_to_writer`, which newer Odin versions keep private.
	data := json.marshal(doc, opt, allocator, loc) or_return
	defer delete(data, allocator, loc)
	_, err := io.write(w, data)
	return err
}

/*
Writes the suite's results as indented JSON to `path`.
*/
@(require_results)
save_json_report :: proc(s: ^Suite, path: string) -> Report_Error {
	return _save_rendered(path, s, proc(w: io.Writer, data: rawptr) -> Report_Error {
		return write_json_document(w, export_document((^Suite)(data), context.temp_allocator))
	})
}

/*
Reads a JSON report written by obench. Everything, strings included, is allocated with
`allocator`, so an arena or the temp allocator can free it all at once.
*/
@(require_results)
read_json_report :: proc(
	path: string,
	allocator := context.temp_allocator,
) -> (
	doc: Export_Document,
	err: Report_Error,
) {
	data := os.read_entire_file(path, allocator) or_return
	json.unmarshal(data, &doc, allocator = allocator) or_return
	// Version 1 files have no per-entry suite name; use the document's.
	for &e in doc.benchmarks {
		if e.suite_name == "" {
			e.suite_name = doc.suite_name
		}
	}
	for &c in doc.complexities {
		if c.suite_name == "" {
			c.suite_name = doc.suite_name
		}
	}
	return doc, nil
}

@(private)
_export_entry_stats :: proc(e: Export_Entry) -> Stats {
	return Stats {
		samples = e.samples,
		batch_size = e.batch_size,
		min_ns = e.min_ns,
		p50_ns = e.p50_ns,
		p95_ns = e.p95_ns,
		p99_ns = e.p99_ns,
		max_ns = e.max_ns,
		mean_ns = e.mean_ns,
		std_dev_ns = e.std_dev_ns,
		ci95_ns = e.ci95_ns,
		mad_ns = e.mad_ns,
		median_cycles = e.median_cycles,
		mb_per_sec = e.mb_per_sec,
		items_per_sec = e.items_per_sec,
		allocs_per_op = e.allocs_per_op,
		resizes_per_op = e.resizes_per_op,
		alloc_bytes_per_op = e.alloc_bytes_per_op,
		temp_allocs_per_op = e.temp_allocs_per_op,
		temp_bytes_per_op = e.temp_bytes_per_op,
		samples_ns = e.samples_ns,
	}
}

@(private)
_has_several_suites :: proc(entries: []Export_Entry) -> bool {
	for e in entries {
		if e.suite_name != entries[0].suite_name {
			return true
		}
	}
	return false
}

/*
Loads a saved JSON report into `out_map`, keyed by `full_name`. Keys and each entry's
`samples_ns` are allocated with `allocator`; `destroy_baseline_map` frees them.

When the file holds several suites (a multi-package CLI run), only the entries of the suite
named `suite_name` are loaded; a single-suite file is loaded regardless of its suite name.
Entries recorded with an error are skipped.
*/
@(require_results)
load_baseline_file :: proc(
	path: string,
	out_map: ^map[string]Stats,
	allocator: runtime.Allocator,
	suite_name := "",
) -> Report_Error {
	doc := read_json_report(path, context.temp_allocator) or_return
	filter_by_suite := suite_name != "" && _has_several_suites(doc.benchmarks)

	for e in doc.benchmarks {
		if e.error != "" || (filter_by_suite && e.suite_name != suite_name) {
			continue
		}
		st := _export_entry_stats(e)
		st.samples_ns = slice.clone(e.samples_ns, allocator)
		if old, found := out_map[e.full_name]; found {
			delete(old.samples_ns, allocator)
			out_map[e.full_name] = st
		} else {
			out_map[strings.clone(e.full_name, allocator)] = st
		}
	}
	return nil
}

/*
Frees a map filled by `load_baseline_file`: its keys, every entry's `samples_ns`, and the map.
`allocator` must be the one passed to `load_baseline_file`.
*/
destroy_baseline_map :: proc(m: ^map[string]Stats, allocator: runtime.Allocator) {
	for k, st in m^ {
		delete(k, allocator)
		delete(st.samples_ns, allocator)
	}
	delete(m^)
	m^ = nil
}

/*
Combines several JSON reports (for example one per package) into a single report at
`output_path`. The suite geomean is recomputed over all benchmarks.
*/
@(require_results)
merge_json_reports :: proc(input_paths: []string, output_path: string) -> Report_Error {
	entries := make([dynamic]Export_Entry, context.temp_allocator)
	complexities := make([dynamic]Export_Complexity, context.temp_allocator)
	suite_names := make([dynamic]string, context.temp_allocator)

	for path in input_paths {
		doc := read_json_report(path, context.temp_allocator) or_return
		append(&entries, ..doc.benchmarks)
		append(&complexities, ..doc.complexities)
		if !slice.contains(suite_names[:], doc.suite_name) {
			append(&suite_names, doc.suite_name)
		}
	}

	log_sum: f64 = 0
	count := 0
	for e in entries {
		if e.error == "" && e.p50_ns > 0 {
			log_sum += math.ln(e.p50_ns)
			count += 1
		}
	}

	merged := Export_Document {
		format_version = REPORT_FORMAT_VERSION,
		obench_version = VERSION,
		odin_version   = ODIN_VERSION,
		optimization   = fmt.tprintf("%v", ODIN_OPTIMIZATION_MODE),
		suite_name     = strings.join(suite_names[:], ", ", context.temp_allocator),
		os             = ODIN_OS_STRING,
		arch           = ODIN_ARCH_STRING,
		geomean_ns     = count > 0 ? math.exp(log_sum / f64(count)) : 0,
		benchmarks     = entries[:],
		complexities   = complexities[:],
	}
	return _save_rendered(output_path, &merged, proc(w: io.Writer, data: rawptr) -> Report_Error {
		return write_json_document(w, (^Export_Document)(data)^)
	})
}
