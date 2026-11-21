package obench

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/info"
import "core:time"

/*
Version of the JSON report layout. Bumped whenever the layout changes. Readers accept older
versions; fields that are missing stay zero.

Version 3 added `samples_ns` (every sample's time per operation) to each benchmark and
`intercept` to each complexity fit. Version 4 added `untimed_allocs`: `false`, or missing in
an older report, means allocations were counted in every timed sample. Version 5 added
`samples_batch_ns` (every sample's overhead-adjusted integer batch duration in nanoseconds)
to each benchmark. Version 6 added where and how a report was made (`created_at`, `git`,
`ci`, `machine`, `build`, `config`, and `clock`), and to each benchmark `peak_heap_bytes`,
the `@zero_alloc` result, the clock overhead (`clamped_samples`, `windows_per_sample`, and
`overhead_share`), and the `better` direction of custom metrics.
*/
REPORT_FORMAT_VERSION :: 6

/*
JSON Schema of the current format version, which every report names in `$schema`. The docs
site publishes it from `schema/` in the repository, one file per format version.
*/
REPORT_SCHEMA_URL :: "https://zeybek.github.io/obench/schema/obench-report-v6.json"

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
	samples_batch_ns:   []u64 `json:"samples_batch_ns,omitempty"`,
	peak_heap_bytes:    i64 `json:"peak_heap_bytes"`,
	zero_alloc:         bool `json:"zero_alloc"`, // The benchmark was checked as `@zero_alloc`.
	zero_alloc_failed:  bool `json:"zero_alloc_failed"`,
	clamped_samples:    int `json:"clamped_samples"`,
	windows_per_sample: f64 `json:"windows_per_sample"`,
	overhead_share:     f64 `json:"overhead_share"`,
	autocorrelation:    f64 `json:"autocorrelation"`, // See `Stats` for these four.
	effective_samples:  f64 `json:"effective_samples"`,
	trend_pct:          f64 `json:"trend_pct"`,
	modes:              int `json:"modes"`,
	// The median of each process when the report combines several (`combine_runs`); the
	// regression test compares these when both sides have at least two.
	process_medians_ns: []f64 `json:"process_medians_ns,omitempty"`,
	// Hardware counters per operation (`Stats.counters`), 0 without `--counters`.
	instructions:       f64 `json:"instructions"`,
	cycles:             f64 `json:"cycles"`,
	branch_misses:      f64 `json:"branch_misses"`,
	cache_misses:       f64 `json:"cache_misses"`,
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
	// The lowest class below `complexity` that fits about as well
	// (`Complexity_Estimate.also_fits`), left out when there is none.
	also_fits:   string `json:"also_fits,omitempty"`,
}

/*
The commit a report's code came from: `OBENCH_GIT_COMMIT`, `OBENCH_GIT_BRANCH`, and
`OBENCH_GIT_DIRTY` (`1` or `true`), which the CLI sets from `git` where it runs, or else
GitHub Actions' `GITHUB_SHA` and `GITHUB_REF_NAME`. Empty when neither is there.
*/
Export_Git :: struct {
	commit: string `json:"commit"`,
	branch: string `json:"branch"`,
	dirty:  bool `json:"dirty"`,
}

/*
The CI run that made a report: GitHub Actions' `GITHUB_RUN_ID` and `GITHUB_RUN_ATTEMPT`.
*/
Export_CI :: struct {
	run_id:      string `json:"run_id"`,
	run_attempt: string `json:"run_attempt"`,
}

/*
The machine a report ran on: the CPU model and its logical core count from `core:sys/info`,
`label`, the name `Config.machine_label` (`--machine`, `OBENCH_MACHINE`) gives the test
machine, and its state during the run (see `Machine_State`), empty where the OS doesn't
say. The host name is never written.
*/
Export_Machine :: struct {
	cpu:        string `json:"cpu"`,
	cores:      int `json:"cores"`,
	label:      string `json:"label"`,
	governor:   string `json:"governor"`,
	boost:      string `json:"boost"`,
	smt:        string `json:"smt"`,
	load_avg:   f64 `json:"load_avg"`,
	on_battery: bool `json:"on_battery"`,
	vm:         bool `json:"vm"`,
}

/*
Compiler settings that change timings besides `optimization`: `-microarch`, whether bounds
checks were `on` or `off`, and the commit of the Odin compiler.
*/
Export_Build :: struct {
	microarch:         string `json:"microarch"`,
	bounds_checks:     string `json:"bounds_checks"`,
	odin_version_hash: string `json:"odin_version_hash"`,
}

/*
The settings a run used.
*/
Export_Run_Config :: struct {
	samples:          int `json:"samples"`,
	warmup_ms:        f64 `json:"warmup_ms"`,
	min_sample_us:    f64 `json:"min_sample_us"`,
	max_bench_ms:     f64 `json:"max_bench_ms"`,
	fixed_batch_size: int `json:"fixed_batch_size"`,
	threshold_pct:    f64 `json:"threshold_pct"`,
}

/*
The clock calibration a run subtracted from its samples, and the time per iteration of an
empty `step` loop (`Suite.empty_loop_ns`).
*/
Export_Clock :: struct {
	overhead_ns:     f64 `json:"overhead_ns"`,
	overhead_cycles: f64 `json:"overhead_cycles"`,
	resolution_ns:   f64 `json:"resolution_ns"`,
	empty_loop_ns:   f64 `json:"empty_loop_ns"`,
}

/*
Root JSON document written by `--save-baseline` and `--json`. A document produced by the
CLI for several packages contains the benchmarks of every suite; each entry carries its
own `suite_name`.
*/
Export_Document :: struct {
	schema:         string `json:"$schema"`,
	format_version: int `json:"format_version"`,
	obench_version: string `json:"obench_version"`,
	odin_version:   string `json:"odin_version"`,
	optimization:   string `json:"optimization"`,
	suite_name:     string `json:"suite_name"`,
	os:             string `json:"os"`,
	arch:           string `json:"arch"`,
	untimed_allocs: bool `json:"untimed_allocs"`,
	created_at:     string `json:"created_at"`, // UTC, RFC 3339
	git:            Export_Git `json:"git"`,
	ci:             Export_CI `json:"ci"`,
	machine:        Export_Machine `json:"machine"`,
	build:          Export_Build `json:"build"`,
	config:         Export_Run_Config `json:"config"`,
	clock:          Export_Clock `json:"clock"`,
	geomean_ns:     f64 `json:"geomean_ns"`,
	// How many processes the report combines (`combine_runs`, `obench --count`); 0 for one.
	processes:      int `json:"processes"`,
	benchmarks:     []Export_Entry `json:"benchmarks"`,
	complexities:   []Export_Complexity `json:"complexities,omitempty"`,
}

/*
Builds an export document for `s`. Most strings point into the suite; the slices and the
strings of `created_at`, `git`, `ci`, `machine`, and `optimization` are allocated with
`allocator`, so an arena or the temp allocator is the easy way to free it all.
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
			samples_batch_ns   = r.stats.samples_batch_ns,
			peak_heap_bytes    = r.stats.peak_heap_bytes,
			zero_alloc         = r.zero_alloc,
			zero_alloc_failed  = r.zero_alloc_failed,
			clamped_samples    = r.stats.clamped_samples,
			windows_per_sample = r.stats.windows_per_sample,
			overhead_share     = r.stats.overhead_share,
			autocorrelation    = r.stats.autocorrelation,
			effective_samples  = r.stats.effective_samples,
			trend_pct          = r.stats.trend_pct,
			modes              = r.stats.modes,
			instructions       = r.stats.counters.instructions,
			cycles             = r.stats.counters.cycles,
			branch_misses      = r.stats.counters.branch_misses,
			cache_misses       = r.stats.counters.cache_misses,
		}
	}

	comp_entries := make([]Export_Complexity, len(s.complexities), allocator, loc)
	for c, i in s.complexities {
		comp_entries[i] = Export_Complexity {
			suite_name  = s.name,
			group_name  = c.group_name,
			bench_name  = c.bench_name,
			complexity  = complexity_string(c.best_class),
			also_fits   = complexity_string(c.also_fits) if c.also_fits != .None else "",
			coefficient = c.coefficient,
			intercept   = c.intercept,
			r_squared   = c.r_squared,
			nrmse       = c.nrmse,
		}
	}

	return Export_Document {
		schema = REPORT_SCHEMA_URL,
		format_version = REPORT_FORMAT_VERSION,
		obench_version = VERSION,
		odin_version = ODIN_VERSION,
		optimization = fmt.aprintf("%v", ODIN_OPTIMIZATION_MODE, allocator = allocator),
		suite_name = s.name,
		os = ODIN_OS_STRING,
		arch = ODIN_ARCH_STRING,
		untimed_allocs = s.config.untimed_alloc_check,
		created_at = _now_rfc3339(allocator),
		git = _git_info(allocator),
		ci = _ci_info(allocator),
		machine = _machine_info(s.config.machine_label, s.machine_state, allocator),
		build = _current_build_info(),
		config = Export_Run_Config {
			samples = s.config.sample_count,
			warmup_ms = time.duration_milliseconds(s.config.warmup_time),
			min_sample_us = time.duration_microseconds(s.config.min_sample_time),
			max_bench_ms = time.duration_milliseconds(s.config.max_bench_time),
			fixed_batch_size = s.config.fixed_batch_size,
			threshold_pct = s.config.noise_threshold_pct,
		},
		clock = Export_Clock {
			overhead_ns = s.clock.overhead_ns,
			overhead_cycles = s.clock.overhead_cycles,
			resolution_ns = s.clock.resolution_ns,
			empty_loop_ns = s.empty_loop_ns,
		},
		geomean_ns = s.summary.geomean_ns,
		benchmarks = entries,
		complexities = comp_entries,
	}
}

@(private)
_now_rfc3339 :: proc(allocator := context.allocator) -> string {
	stamp, _ := time.time_to_rfc3339(time.now(), 0, false, allocator)
	return stamp
}

@(private)
_env_flag :: proc(key: string) -> bool {
	val := os.get_env(key, context.temp_allocator)
	return val == "1" || val == "true"
}

@(private)
_git_info :: proc(allocator := context.allocator) -> Export_Git {
	commit := os.get_env("OBENCH_GIT_COMMIT", allocator)
	if commit != "" {
		return {
			commit = commit,
			branch = os.get_env("OBENCH_GIT_BRANCH", allocator),
			dirty = _env_flag("OBENCH_GIT_DIRTY"),
		}
	}
	delete(commit, allocator)
	return {
		commit = os.get_env("GITHUB_SHA", allocator),
		branch = os.get_env("GITHUB_REF_NAME", allocator),
	}
}

@(private)
_ci_info :: proc(allocator := context.allocator) -> Export_CI {
	return {
		run_id = os.get_env("GITHUB_RUN_ID", allocator),
		run_attempt = os.get_env("GITHUB_RUN_ATTEMPT", allocator),
	}
}

@(private)
_machine_info :: proc(
	label: string,
	state: Machine_State,
	allocator := context.allocator,
) -> Export_Machine {
	return {
		cpu = strings.clone(_cpu_model(), allocator),
		cores = _logical_cores(),
		label = strings.clone(label, allocator),
		governor = strings.clone(state.governor, allocator),
		boost = strings.clone(state.boost, allocator),
		smt = strings.clone(state.smt, allocator),
		load_avg = state.load_avg,
		on_battery = state.on_battery,
		vm = state.vm,
	}
}

// The CPU model as `core:sys/info` names it.
@(private)
_cpu_model :: proc() -> string {
	return strings.trim_space(info.cpu_name())
}

@(private)
_logical_cores :: proc() -> int {
	_, logical, _ := info.cpu_core_count()
	if logical <= 0 {
		// `core:sys/info` reads /proc/cpuinfo fields that Linux on ARM doesn't have.
		logical = os.get_processor_core_count()
	}
	return logical
}

@(private)
_current_build_info :: proc() -> Export_Build {
	return {
		microarch = ODIN_MICROARCH_STRING,
		bounds_checks = "off" when ODIN_NO_BOUNDS_CHECK else "on",
		odin_version_hash = ODIN_VERSION_HASH,
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
		pretty         = true,
		use_spaces     = true,
		spaces         = 2,
		use_enum_names = true,
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

Apart from backfilling missing `suite_name` fields on format version 1 entries, this
procedure returns the raw decoded wire entries without validating per-entry invariants such
as `samples_batch_ns`. Callers that convert entries into `Stats` (such as
`load_baseline_file`, `suite_run`, and `write_comparison`) validate and drop invalid
`samples_batch_ns` slices automatically.
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

@(private, require_results)
_valid_batch_samples :: proc(e: Export_Entry) -> []u64 {
	if len(e.samples_batch_ns) == 0 || e.batch_size <= 0 || e.samples <= 0 {
		return nil
	}
	if len(e.samples_batch_ns) != e.samples ||
	   (len(e.samples_ns) > 0 && len(e.samples_batch_ns) != len(e.samples_ns)) {
		return nil
	}
	for v in e.samples_batch_ns {
		if v > u64(max(i64)) {
			return nil
		}
	}
	return e.samples_batch_ns
}

@(private)
_export_entry_stats :: proc(e: Export_Entry) -> Stats {
	st := Stats {
		samples            = e.samples,
		batch_size         = e.batch_size,
		min_ns             = e.min_ns,
		p50_ns             = e.p50_ns,
		p95_ns             = e.p95_ns,
		p99_ns             = e.p99_ns,
		max_ns             = e.max_ns,
		mean_ns            = e.mean_ns,
		std_dev_ns         = e.std_dev_ns,
		ci95_ns            = e.ci95_ns,
		mad_ns             = e.mad_ns,
		median_cycles      = e.median_cycles,
		mb_per_sec         = e.mb_per_sec,
		items_per_sec      = e.items_per_sec,
		allocs_per_op      = e.allocs_per_op,
		resizes_per_op     = e.resizes_per_op,
		alloc_bytes_per_op = e.alloc_bytes_per_op,
		temp_allocs_per_op = e.temp_allocs_per_op,
		temp_bytes_per_op  = e.temp_bytes_per_op,
		samples_ns         = e.samples_ns,
		process_medians_ns = e.process_medians_ns,
		samples_batch_ns   = _valid_batch_samples(e),
		peak_heap_bytes    = e.peak_heap_bytes,
		clamped_samples    = e.clamped_samples,
		windows_per_sample = e.windows_per_sample,
		overhead_share     = e.overhead_share,
	}
	cm_count := min(len(e.custom_metrics), MAX_CUSTOM_METRICS)
	st.custom_metrics_count = cm_count
	for i in 0 ..< cm_count {
		st.custom_metrics[i] = e.custom_metrics[i]
	}
	return st
}

@(private)
_has_several_suites :: proc(entries: []Export_Entry) -> bool {
	for &e in entries {
		if e.suite_name != entries[0].suite_name {
			return true
		}
	}
	return false
}

/*
Loads a saved JSON report into `out_map`, keyed by `full_name`. Keys and each valid entry's
`samples_ns`, `samples_batch_ns`, `process_medians_ns`, and custom metric units are allocated
with `allocator`; `destroy_baseline_map` frees them. Invalid `samples_batch_ns` slices (for example
`samples <= 0`, `batch_size <= 0`, mismatched lengths, or values exceeding `max(i64)`) are
dropped to `nil`.

When the file holds several suites (a multi-package CLI run), or `match_suite` is set, only
the entries of the suite named `suite_name` are loaded; otherwise a single-suite file is
loaded regardless of its suite name. Entries recorded with an error are skipped.

It loads the timings whatever build wrote them. `suite_run` also checks the report's
optimization mode, OS, and architecture against the running program.
*/
@(require_results)
load_baseline_file :: proc(
	path: string,
	out_map: ^map[string]Stats,
	allocator: runtime.Allocator,
	suite_name := "",
	match_suite := false,
) -> Report_Error {
	doc := read_json_report(path, context.temp_allocator) or_return
	_fill_baseline_map(doc, out_map, allocator, suite_name, match_suite)
	return nil
}

// The build settings a report was written with that change every timing in it.
@(private)
_Build_Settings :: struct {
	optimization:  string,
	os:            string,
	arch:          string,
	microarch:     string,
	bounds_checks: string,
}

@(private)
_current_build :: proc() -> _Build_Settings {
	b := _current_build_info()
	return {
		fmt.tprintf("%v", ODIN_OPTIMIZATION_MODE),
		ODIN_OS_STRING,
		ODIN_ARCH_STRING,
		b.microarch,
		b.bounds_checks,
	}
}

@(private)
_document_build :: proc(doc: Export_Document) -> _Build_Settings {
	return {doc.optimization, doc.os, doc.arch, doc.build.microarch, doc.build.bounds_checks}
}

// Reports whether timings from builds `a` and `b` can't be compared: their optimization mode,
// OS, architecture, `-microarch`, or bounds checks differ. A field that a report leaves empty,
// as reports older than format version 6 do for the last two, is not held against it.
@(private)
_builds_differ :: proc(a, b: _Build_Settings) -> bool {
	differ :: proc(x, y: string) -> bool {
		return x != "" && y != "" && x != y
	}
	return(
		differ(a.optimization, b.optimization) ||
		differ(a.os, b.os) ||
		differ(a.arch, b.arch) ||
		differ(a.microarch, b.microarch) ||
		differ(a.bounds_checks, b.bounds_checks) \
	)
}

// `-o:Speed darwin/arm64 -microarch:native -no-bounds-check`, for warnings.
@(private)
_build_string :: proc(b: _Build_Settings) -> string {
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "-o:%s %s/%s", b.optimization, b.os, b.arch)
	if b.microarch != "" {
		fmt.sbprintf(&sb, " -microarch:%s", b.microarch)
	}
	if b.bounds_checks == "off" {
		strings.write_string(&sb, " -no-bounds-check")
	}
	return strings.to_string(sb)
}

/*
Reports whether a benchmark with these counts takes longer when allocations are counted in
every timed sample (see `Config.untimed_alloc_check`): counting adds its cost to every
allocator call. A benchmark that doesn't allocate takes the same time either way, so only
reports with one that allocates can't be compared across the two ways of counting.
*/
@(private)
_allocates :: proc "contextless" (allocs_per_op, resizes_per_op, temp_allocs_per_op: f64) -> bool {
	return allocs_per_op > 0 || resizes_per_op > 0 || temp_allocs_per_op > 0
}

// `in every timed sample` or `in one untimed batch`, for warnings.
@(private)
_alloc_counting_string :: proc(untimed: bool) -> string {
	return "in one untimed batch" if untimed else "in every timed sample"
}

// The flag that makes a run count allocations the way a report with `untimed` did.
@(private)
_alloc_counting_flag :: proc(untimed: bool) -> string {
	return "--untimed-allocs" if untimed else "--timed-allocs"
}

// Fills `out_map` from a report that has already been read (see `load_baseline_file`).
@(private)
_fill_baseline_map :: proc(
	doc: Export_Document,
	out_map: ^map[string]Stats,
	allocator: runtime.Allocator,
	suite_name := "",
	match_suite := false,
) {
	filter_by_suite := suite_name != "" && (match_suite || _has_several_suites(doc.benchmarks))

	for e in doc.benchmarks {
		if e.error != "" || (filter_by_suite && e.suite_name != suite_name) {
			continue
		}
		st := _export_entry_stats(e)
		st.samples_ns = slice.clone(e.samples_ns, allocator)
		st.samples_batch_ns = slice.clone(st.samples_batch_ns, allocator)
		st.process_medians_ns = slice.clone(e.process_medians_ns, allocator)
		for i in 0 ..< st.custom_metrics_count {
			st.custom_metrics[i].unit = strings.clone(st.custom_metrics[i].unit, allocator)
		}
		if old, found := out_map[e.full_name]; found {
			delete(old.samples_ns, allocator)
			delete(old.samples_batch_ns, allocator)
			delete(old.process_medians_ns, allocator)
			for i in 0 ..< old.custom_metrics_count {
				delete(old.custom_metrics[i].unit, allocator)
			}
			out_map[e.full_name] = st
		} else {
			out_map[strings.clone(e.full_name, allocator)] = st
		}
	}
}

/*
Frees a map filled by `load_baseline_file`: its keys, every entry's `samples_ns`,
`samples_batch_ns`, `process_medians_ns`, custom metric units, and the map. `allocator` must be the one passed to
`load_baseline_file`.
*/
destroy_baseline_map :: proc(m: ^map[string]Stats, allocator: runtime.Allocator) {
	for k, st in m^ {
		delete(k, allocator)
		delete(st.samples_ns, allocator)
		delete(st.samples_batch_ns, allocator)
		delete(st.process_medians_ns, allocator)
		for i in 0 ..< st.custom_metrics_count {
			delete(st.custom_metrics[i].unit, allocator)
		}
	}
	delete(m^)
	m^ = nil
}

/*
Combines several JSON reports (for example one per package) into a single report at
`output_path`. The suite geomean is recomputed over all benchmarks. The build fields
(`obench_version`, `odin_version`, `optimization`, `os`, `arch`) come from the first report, since the
reports' runners were built separately from the program that merges them; a part that
disagrees is reported on stderr.
*/
@(require_results)
merge_json_reports :: proc(input_paths: []string, output_path: string) -> Report_Error {
	entries := make([dynamic]Export_Entry, context.temp_allocator)
	complexities := make([dynamic]Export_Complexity, context.temp_allocator)
	suite_names := make([dynamic]string, context.temp_allocator)
	first: Export_Document

	for path, i in input_paths {
		doc := read_json_report(path, context.temp_allocator) or_return
		if i == 0 {
			first = doc
		} else {
			if doc.odin_version != first.odin_version ||
			   doc.optimization != first.optimization ||
			   doc.os != first.os ||
			   doc.arch != first.arch {
				fmt.eprintfln(
					"obench: warning: '%s' was built with Odin %s -o:%s for %s/%s, unlike '%s'",
					path,
					doc.odin_version,
					doc.optimization,
					doc.os,
					doc.arch,
					input_paths[0],
				)
			}
			if doc.untimed_allocs != first.untimed_allocs {
				fmt.eprintfln(
					"obench: warning: '%s' counted allocations %s, unlike '%s'",
					path,
					_alloc_counting_string(doc.untimed_allocs),
					input_paths[0],
				)
			}
		}
		append(&entries, ..doc.benchmarks)
		append(&complexities, ..doc.complexities)
		if !slice.contains(suite_names[:], doc.suite_name) {
			append(&suite_names, doc.suite_name)
		}
	}
	if len(input_paths) == 0 {
		first = Export_Document {
			odin_version   = ODIN_VERSION,
			optimization   = fmt.tprintf("%v", ODIN_OPTIMIZATION_MODE),
			os             = ODIN_OS_STRING,
			arch           = ODIN_ARCH_STRING,
			untimed_allocs = DEFAULT_UNTIMED_ALLOCS,
		}
	}

	log_sum: f64 = 0
	count := 0
	for &e in entries {
		if e.error == "" && e.p50_ns > 0 {
			log_sum += math.ln(e.p50_ns)
			count += 1
		}
	}

	merged := Export_Document {
		schema         = REPORT_SCHEMA_URL,
		format_version = REPORT_FORMAT_VERSION,
		obench_version = first.obench_version if first.obench_version != "" else VERSION,
		odin_version   = first.odin_version,
		optimization   = first.optimization,
		suite_name     = strings.join(suite_names[:], ", ", context.temp_allocator),
		os             = first.os,
		arch           = first.arch,
		untimed_allocs = first.untimed_allocs,
		created_at     = first.created_at,
		git            = first.git,
		ci             = first.ci,
		machine        = first.machine,
		build          = first.build,
		config         = first.config,
		clock          = first.clock,
		geomean_ns     = count > 0 ? math.exp(log_sum / f64(count)) : 0,
		processes      = first.processes,
		benchmarks     = entries[:],
		complexities   = complexities[:],
	}
	return _save_rendered(output_path, &merged, proc(w: io.Writer, data: rawptr) -> Report_Error {
		return write_json_document(w, (^Export_Document)(data)^)
	})
}
