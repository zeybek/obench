package main

import obench "../../obench"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

/*
`--count K`: builds the package once and runs it in K processes. Each one starts with a
random `OBENCH_ENV_PADDING` of up to 4 KiB and a random `OBENCH_STACK_OFFSET`, so they don't
all share one memory layout. The first process prints its table and the others only their
summary line. Their JSON reports are combined (`obench.combine_runs`) into
`outputs.json`, `outputs.baseline` and `outputs.html`. With `--baseline`, the combined report
is compared like `obench compare` does and gates the run (see `obench.comparison_exit_code`).
Returns the exit status.
*/
run_package_repeated :: proc(
	pkg: Discovered_Package,
	index: int,
	suite_name: string,
	work_dir: string,
	opts: CLI_Options,
	outputs: Package_Outputs,
	reported_ols: ^map[string]bool = nil,
) -> int {
	exe, built := build_package(pkg, index, suite_name, work_dir, opts, reported_ols)
	if !built {
		return EXIT_FAILURE
	}
	child := measuring_options(opts)
	code := 0
	docs := make([dynamic]obench.Export_Document, context.temp_allocator)
	for k in 0 ..< opts.count {
		part, _ := filepath.join(
			{work_dir, fmt.tprintf("process_%d_%d.json", index, k)},
			context.temp_allocator,
		)
		child.quiet = opts.quiet || k > 0
		if k > 0 && !opts.quiet {
			fmt.printf("obench: %s, process %d of %d: ", suite_name, k + 1, opts.count)
		}
		doc, run_code, ok := measure_process(exe, child, part)
		code = worse_exit_code(code, run_code)
		if !ok {
			fmt.eprintfln("obench: %s: process %d wrote no report", suite_name, k + 1)
			continue
		}
		append(&docs, doc)
	}
	if len(docs) == 0 {
		return worse_exit_code(code, EXIT_FAILURE)
	}
	combined := obench.combine_runs(docs[:], context.temp_allocator)
	_print_process_medians(combined, !opts.no_color && obench.stdout_wants_color())

	for path in ([]string{outputs.json, outputs.baseline}) {
		if path != "" && !_write_document(path, combined) {
			code = worse_exit_code(code, EXIT_FAILURE)
		}
	}

	baseline: Maybe(obench.Export_Document)
	if opts.load_baseline != "" {
		base, err := obench.read_json_report(opts.load_baseline, context.temp_allocator)
		if err != nil {
			// A failure, as in a single process, since the path may be misspelled.
			fmt.eprintfln("obench: could not read baseline '%s' (%v)", opts.load_baseline, err)
			code = worse_exit_code(code, EXIT_FAILURE)
		} else {
			if outputs.match_baseline_suite {
				// Only this package's suite, as a single process compares it.
				own := make([dynamic]obench.Export_Entry, context.temp_allocator)
				for e in base.benchmarks {
					if e.suite_name == suite_name {
						append(&own, e)
					}
				}
				base.benchmarks = own[:]
			}
			baseline = base
			sb := strings.builder_make(context.temp_allocator)
			summary := obench.write_comparison(
				strings.to_writer(&sb),
				base,
				combined,
				opts.threshold_pct,
				!opts.no_color && obench.stdout_wants_color(),
			)
			_, _ = os.write_string(os.stdout, strings.to_string(sb))
			code = worse_exit_code(
				code,
				obench.comparison_exit_code(
					summary,
					opts.fail_on_regression,
					opts.fail_on_alloc_regression,
				),
			)
		}
	}

	if outputs.html != "" {
		sb := strings.builder_make(context.temp_allocator)
		obench.write_html_report(strings.to_writer(&sb), combined, baseline)
		if err := os.write_entire_file(outputs.html, sb.buf[:]); err != nil {
			fmt.eprintfln("obench: could not write HTML report to '%s' (%v)", outputs.html, err)
			code = worse_exit_code(code, EXIT_FAILURE)
		}
	}
	return code
}

@(private = "file")
_write_document :: proc(path: string, doc: obench.Export_Document) -> bool {
	sb := strings.builder_make(context.temp_allocator)
	if obench.write_json_document(strings.to_writer(&sb), doc, context.temp_allocator) != nil {
		fmt.eprintfln("obench: could not render the JSON report for '%s'", path)
		return false
	}
	if err := os.write_entire_file(path, sb.buf[:]); err != nil {
		fmt.eprintfln("obench: could not write JSON report to '%s' (%v)", path, err)
		return false
	}
	return true
}

// Every benchmark's median over all processes, with the range of the process medians.
@(private = "file")
_print_process_medians :: proc(doc: obench.Export_Document, color: bool) {
	bold, dim, reset := "", "", ""
	if color {
		bold, dim, reset = "\x1b[1m", "\x1b[2m", "\x1b[0m"
	}
	width := len("benchmark")
	for e in doc.benchmarks {
		width = max(width, len(e.full_name))
	}
	fmt.printf(
		"\n%sobench:%s %s%s over %d processes%s\n",
		bold,
		reset,
		dim,
		doc.benchmarks[0].suite_name if len(doc.benchmarks) > 0 else doc.suite_name,
		doc.processes,
		reset,
	)
	fmt.printf(
		"%s%-*s │ %12s │ %s%s\n",
		bold,
		width,
		"benchmark",
		"median(p50)",
		"process medians",
		reset,
	)
	for e in doc.benchmarks {
		if e.error != "" {
			fmt.printf("%-*s │ %12s │ ERROR: %s\n", width, e.full_name, "", e.error)
			continue
		}
		medians := slice.clone(e.process_medians_ns, context.temp_allocator)
		slice.sort(medians)
		spread := ""
		if len(medians) > 0 {
			spread = fmt.tprintf(
				"%s to %s",
				obench.format_duration_ns(medians[0]),
				obench.format_duration_ns(medians[len(medians) - 1]),
			)
		}
		fmt.printf(
			"%-*s │ %12s │ %s\n",
			width,
			e.full_name,
			obench.format_duration_ns(e.p50_ns),
			spread,
		)
	}
	fmt.println()
}

// Process medians a side from which a comparison always has a 95% interval
// (`obench.hodges_lehmann_shift`).
MIN_PROCESSES_FOR_VERDICT :: 4

/*
The warning for a `--count` or `--rounds` below `MIN_PROCESSES_FOR_VERDICT`, or "" when
`processes` is enough or the run is a single process. `flag` is the flag as typed.
*/
few_processes_warning :: proc(flag: string, processes: int) -> string {
	if processes < 2 || processes >= MIN_PROCESSES_FOR_VERDICT {
		return ""
	}
	return fmt.tprintf(
		"%s %d: with fewer than %d processes on both sides a comparison can be left without a 95%% interval, and then it decides nothing",
		flag,
		processes,
		MIN_PROCESSES_FOR_VERDICT,
	)
}

// The options of a process that only measures: the combined report is compared and saved
// afterwards.
measuring_options :: proc(opts: CLI_Options) -> CLI_Options {
	child := opts
	child.load_baseline = ""
	child.fail_on_regression = false
	child.fail_on_alloc_regression = false
	return child
}

/*
Runs `exe` once with `opts`, writing its JSON report to `part`, from a random amount of
`OBENCH_ENV_PADDING` (up to 4 KiB) and a random `OBENCH_STACK_OFFSET` (up to 4 KiB), so
repeated processes don't all share one memory layout. Returns the report, the exit status,
and whether the report could be read.
*/
measure_process :: proc(
	exe: string,
	opts: CLI_Options,
	part: string,
) -> (
	doc: obench.Export_Document,
	code: int,
	ok: bool,
) {
	padding := strings.repeat("x", rand.int_max(4097), context.temp_allocator)
	_ = os.set_env("OBENCH_ENV_PADDING", padding)
	_ = os.set_env("OBENCH_STACK_OFFSET", fmt.tprintf("%d", 16 * rand.int_max(257)))
	defer {
		_ = os.unset_env("OBENCH_ENV_PADDING")
		_ = os.unset_env("OBENCH_STACK_OFFSET")
	}
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, exe)
	append(&cmd, .._runtime_args(opts, Package_Outputs{json = part}))
	code = worse_exit_code(0, _run_process(cmd[:]))
	read, err := obench.read_json_report(part, context.temp_allocator)
	if err != nil {
		return {}, worse_exit_code(code, EXIT_FAILURE), false
	}
	return read, code, true
}
