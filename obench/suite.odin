package obench

import "base:runtime"
import "core:fmt"
import "core:strings"

/*
A single registered benchmark entry inside a `Group`.
*/
Entry :: struct {
	name:               string,
	procedure:          Bench_Proc,
	enforce_zero_alloc: bool,
	user_ptr:           rawptr,
}

/*
Outcome of executing one benchmark entry (for one parameter / thread configuration).
*/
Result :: struct {
	group_name:          string,
	name:                string,
	full_name:           string,
	param:               int,
	has_param:           bool,
	threads:             int,
	has_threads:         bool,
	stats:               Stats,
	diff:                Baseline_Diff,
	speedup_vs_fastest:  f64, // 1.0 = fastest in group/param cohort; larger means slower
	speedup_vs_first:    f64, // > 1.0 means faster than the first entry in the cohort
	speedup_significant: bool, // `speedup_vs_first` passed the same significance test as baselines
	zero_alloc:          bool, // Checked as `@zero_alloc` (by annotation, `expect_zero_allocs`, or `--zero-alloc`)
	zero_alloc_failed:   bool,
	violation_loc:       runtime.Source_Code_Location,
	violation_size:      int,
	error:               Bench_Error,
}

/*
A group of related benchmarks that can share parameters and thread counts and are compared
side by side. Groups are heap-allocated by `group_add`, so the returned pointer stays valid
until `suite_destroy`.
*/
Group :: struct {
	name:      string,
	params:    [dynamic]int,
	threads:   [dynamic]int,
	entries:   [dynamic]Entry,
	allocator: runtime.Allocator,
}

/*
Top-level benchmark suite.
*/
Suite :: struct {
	name:                     string,
	config:                   Config,
	clock:                    Clock_Calibration,
	groups:                   [dynamic]^Group,
	results:                  [dynamic]Result,
	complexities:             [dynamic]Complexity_Estimate,
	summary:                  Suite_Summary,
	failed_zero_alloc:        int,
	failed_regressions:       int,
	failed_alloc_regressions: int, // Benchmarks whose allocations grew, with `fail_on_alloc_regression`
	failed_errors:            int, // Benchmarks that misused the `Bencher` protocol
	failed_io:                int, // Trace or report files that could not be written
	// Baselines that can't be compared with this run: unreadable, built with another
	// optimization mode, OS, or architecture, counting allocations the other way, or holding
	// none of the suite's benchmarks. See `suite_exit_code`.
	failed_baseline:          int,
	// The machine's state when the suite last ran (see `read_machine_state`).
	machine_state:            Machine_State,
	// Time per iteration of an empty `for step(b) {}` loop, timed after the benchmarks. A
	// result near it most likely had its work optimized away. 0 when nothing ran or with
	// `Config.test_mode`.
	empty_loop_ns:            f64,
	// Why `Config.counters` gave no hardware counters, like "perf_event_open failed with
	// EACCES"; "" when it did or wasn't set.
	counters_unavailable:     string,
	allocator:                runtime.Allocator,
}

/*
Creates a new benchmark suite. When `config` is `nil`, `default_config()` is used.
The suite copies `name` and every string in `config`.
*/
@(require_results)
suite_create :: proc(
	name: string,
	config: Maybe(Config) = nil,
	allocator := context.allocator,
	loc := #caller_location,
) -> Suite {
	cfg := config.? or_else default_config()
	_clone_config_strings(&cfg, allocator)
	return Suite {
		name         = strings.clone(name, allocator, loc),
		config       = cfg,
		// Calibrating spins until the clock ticks, which would change an instruction count.
		clock        = clock_calibrate() if cfg.count_iterations <= 0 else {},
		groups       = make([dynamic]^Group, allocator, loc),
		results      = make([dynamic]Result, allocator, loc),
		complexities = make([dynamic]Complexity_Estimate, allocator, loc),
		allocator    = allocator,
	}
}

@(private = "file")
_clone_config_strings :: proc(cfg: ^Config, allocator: runtime.Allocator) {
	cfg.filter = strings.clone(cfg.filter, allocator)
	cfg.skip = strings.clone(cfg.skip, allocator)
	cfg.exact = strings.clone(cfg.exact, allocator)
	cfg.baseline_load_path = strings.clone(cfg.baseline_load_path, allocator)
	cfg.baseline_save_path = strings.clone(cfg.baseline_save_path, allocator)
	cfg.json_export_path = strings.clone(cfg.json_export_path, allocator)
	cfg.md_export_path = strings.clone(cfg.md_export_path, allocator)
	cfg.csv_export_path = strings.clone(cfg.csv_export_path, allocator)
	cfg.html_export_path = strings.clone(cfg.html_export_path, allocator)
	cfg.spall_export_path = strings.clone(cfg.spall_export_path, allocator)
	cfg.machine_label = strings.clone(cfg.machine_label, allocator)
}

@(private = "file")
_delete_config_strings :: proc(cfg: ^Config, allocator: runtime.Allocator) {
	delete(cfg.filter, allocator)
	delete(cfg.skip, allocator)
	delete(cfg.exact, allocator)
	delete(cfg.baseline_load_path, allocator)
	delete(cfg.baseline_save_path, allocator)
	delete(cfg.json_export_path, allocator)
	delete(cfg.md_export_path, allocator)
	delete(cfg.csv_export_path, allocator)
	delete(cfg.html_export_path, allocator)
	delete(cfg.spall_export_path, allocator)
	delete(cfg.machine_label, allocator)
	cfg^ = {}
}

// Frees what a `Result` owns.
@(private)
_destroy_result :: proc(s: ^Suite, r: ^Result) {
	delete(r.full_name, s.allocator)
	delete(r.stats.samples_ns, s.allocator)
	delete(r.stats.samples_batch_ns, s.allocator)
	for i in 0 ..< r.stats.custom_metrics_count {
		delete(r.stats.custom_metrics[i].unit, s.allocator)
	}
}

@(private)
_clear_results :: proc(s: ^Suite) {
	for &r in s.results {
		_destroy_result(s, &r)
	}
	clear(&s.results)
	clear(&s.complexities)
	s.summary = {}
	s.failed_zero_alloc = 0
	s.failed_regressions = 0
	s.failed_alloc_regressions = 0
	s.failed_errors = 0
	s.failed_io = 0
	s.failed_baseline = 0
	machine_state_destroy(&s.machine_state, s.allocator)
	s.empty_loop_ns = 0
	delete(s.counters_unavailable, s.allocator)
	s.counters_unavailable = ""
}

/*
Frees all resources owned by a `Suite`.
*/
suite_destroy :: proc(s: ^Suite) {
	if s == nil {
		return
	}
	for g in s.groups {
		for e in g.entries {
			delete(e.name, g.allocator)
		}
		delete(g.name, g.allocator)
		delete(g.params)
		delete(g.threads)
		delete(g.entries)
		free(g, g.allocator)
	}
	delete(s.groups)
	_clear_results(s)
	delete(s.results)
	delete(s.complexities)
	_delete_config_strings(&s.config, s.allocator)
	delete(s.name, s.allocator)
	s.name = ""
}

/*
Adds a named benchmark group to the suite and returns a stable pointer to it.
*/
@(require_results)
group_add :: proc(s: ^Suite, name: string, loc := #caller_location) -> ^Group {
	g := new(Group, s.allocator, loc)
	g^ = Group {
		name      = strings.clone(name, s.allocator, loc),
		params    = make([dynamic]int, s.allocator, loc),
		threads   = make([dynamic]int, s.allocator, loc),
		entries   = make([dynamic]Entry, s.allocator, loc),
		allocator = s.allocator,
	}
	append(&s.groups, g, loc)
	return g
}

/*
Attaches parameter values (e.g. `[]int{64, 1024, 65536}`) to a benchmark group.
Every benchmark in the group runs once per parameter, and Big-O complexity is estimated
when there are at least 3 distinct parameters.
*/
group_params :: proc(g: ^Group, params: []int, loc := #caller_location) {
	clear(&g.params)
	append(&g.params, ..params, loc = loc)
}

/*
Attaches thread counts (e.g. `[]int{1, 2, 4, 8}`) to a benchmark group for contention scaling.
Non-positive counts are ignored.
*/
group_threads :: proc(g: ^Group, thread_counts: []int, loc := #caller_location) {
	clear(&g.threads)
	for t in thread_counts {
		if t > 0 {
			append(&g.threads, t, loc)
		}
	}
}

/*
Registers a benchmark procedure in a group. `name` is copied.
*/
group_bench :: proc(
	g: ^Group,
	name: string,
	procedure: Bench_Proc,
	zero_alloc := false,
	user_ptr: rawptr = nil,
	loc := #caller_location,
) {
	append(
		&g.entries,
		Entry {
			name = strings.clone(name, g.allocator, loc),
			procedure = procedure,
			enforce_zero_alloc = zero_alloc,
			user_ptr = user_ptr,
		},
		loc,
	)
}

/*
Registers a standalone benchmark in the suite's `"default"` group (created on first use).
*/
bench :: proc(
	s: ^Suite,
	name: string,
	procedure: Bench_Proc,
	zero_alloc := false,
	user_ptr: rawptr = nil,
	loc := #caller_location,
) {
	for g in s.groups {
		if g.name == "default" {
			group_bench(g, name, procedure, zero_alloc, user_ptr, loc)
			return
		}
	}
	g := group_add(s, "default", loc)
	group_bench(g, name, procedure, zero_alloc, user_ptr, loc)
}

/*
Formats the canonical full identifier for a benchmark (`group::name[param]/tN`).
The `"default"` group name is omitted.
*/
@(require_results)
format_full_name :: proc(
	group_name, bench_name: string,
	param_val: int,
	has_param: bool,
	thread_val: int = 1,
	has_threads: bool = false,
	allocator := context.allocator,
) -> string {
	prefix :=
		group_name != "" && group_name != "default" ? fmt.tprintf("%s::%s", group_name, bench_name) : bench_name
	if has_param && has_threads {
		return fmt.aprintf("%s[%d]/t%d", prefix, param_val, thread_val, allocator = allocator)
	}
	if has_param {
		return fmt.aprintf("%s[%d]", prefix, param_val, allocator = allocator)
	}
	if has_threads {
		return fmt.aprintf("%s/t%d", prefix, thread_val, allocator = allocator)
	}
	return strings.clone(prefix, allocator)
}
