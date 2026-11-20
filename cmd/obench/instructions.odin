package main

import obench "../../obench"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// Iterations of the shorter Cachegrind run when `--batch-size` doesn't set them; the longer
// run has twice as many.
DEFAULT_COUNT_ITERATIONS :: 100

INSTRUCTIONS_FORMAT :: "obench-instructions"

// One benchmark's instructions per operation, as `--instructions` measures them.
Instruction_Entry :: struct {
	suite_name:          string `json:"suite_name"`,
	full_name:           string `json:"full_name"`,
	instructions_per_op: f64 `json:"instructions_per_op"`,
}

/*
The report `--instructions` writes with `--json` or `--save-baseline` and reads with
`--baseline`. `format` is always "obench-instructions".
*/
Instruction_Report :: struct {
	format:         string `json:"format"`,
	format_version: int `json:"format_version"`,
	obench_version: string `json:"obench_version"`,
	optimization:   string `json:"optimization"`,
	os:             string `json:"os"`,
	arch:           string `json:"arch"`,
	iterations:     int `json:"iterations"`,
	benchmarks:     []Instruction_Entry `json:"benchmarks"`,
}

/*
`obench --instructions`: builds every package once and runs each selected benchmark under
Cachegrind twice, with N and 2N iterations (`--batch-size`, default 100) and nothing else
(`Config.count_iterations`). (I(2N) - I(N)) / N is its instructions per operation: the
setup outside the loop, the process start, and the one validating iteration cancel out.
Returns the exit status: 1 when a benchmark failed, the baseline file can't be read, or, with
`--fail-on-regression`, a benchmark got more instructions than `--threshold` allows over the
baseline, and 3 when the gate's baseline can't be compared.
*/
run_instructions :: proc(packages: []Discovered_Package, opts: CLI_Options) -> int {
	if _, _, _, err := os.process_exec(
		{command = {"valgrind", "--version"}},
		context.temp_allocator,
	); err != nil {
		fmt.eprintln(
			"obench: --instructions runs the benchmarks under Valgrind's Cachegrind, but 'valgrind' isn't on PATH",
		)
		return EXIT_FAILURE
	}
	work_dir, tmp_err := os.make_directory_temp("", "obench-*", context.temp_allocator)
	if tmp_err != nil {
		fmt.eprintfln("obench: could not create a temporary directory: %v", tmp_err)
		return EXIT_FAILURE
	}
	defer os.remove_all(work_dir)

	n := opts.batch_size if opts.batch_size > 0 else DEFAULT_COUNT_ITERATIONS
	selection := obench.Config {
		filter = opts.filter,
		skip   = opts.skip,
		exact  = opts.exact,
	}
	names := suite_names(packages, opts.target_path)
	entries := make([dynamic]Instruction_Entry, context.temp_allocator)
	code := 0

	for &pkg, idx in packages {
		if pkg.has_main {
			fmt.eprintfln(
				"obench: %s runs its own main(), so --instructions can't run its benchmarks one at a time; skipped",
				pkg.dir_path,
			)
			continue
		}
		if problems := check_package(pkg); len(problems) > 0 {
			for p in problems {
				fmt.eprintfln("obench: %s", p)
			}
			code = worse_exit_code(code, EXIT_FAILURE)
			continue
		}
		exe, built := build_package(pkg, idx, names[idx], work_dir, opts)
		if !built {
			code = worse_exit_code(code, EXIT_FAILURE)
			continue
		}
		for b in pkg.benches {
			params := b.params[:] if len(b.params) > 0 else []int{0}
			threads := b.threads[:] if len(b.threads) > 0 else []int{1}
			for p in params {
				for t in threads {
					full := obench.format_full_name(
						b.group_name,
						b.bench_name,
						p,
						len(b.params) > 0,
						t,
						len(b.threads) > 0,
						context.temp_allocator,
					)
					if !obench.benchmark_selected(selection, full) {
						continue
					}
					if t > 1 {
						// Threads waiting on each other run a different number of times.
						fmt.eprintfln(
							"obench: %s runs on %d threads, so its count isn't exact; skipped",
							full,
							t,
						)
						continue
					}
					short, ok_short := _cachegrind_count(exe, full, n)
					long, ok_long := _cachegrind_count(exe, full, 2 * n)
					if !ok_short || !ok_long {
						code = worse_exit_code(code, EXIT_FAILURE)
						continue
					}
					append(
						&entries,
						Instruction_Entry {
							suite_name = names[idx],
							full_name = full,
							instructions_per_op = f64(long - short) / f64(n),
						},
					)
				}
			}
		}
	}

	report := Instruction_Report {
		format         = INSTRUCTIONS_FORMAT,
		format_version = 1,
		obench_version = obench.VERSION,
		optimization   = opts.opt_mode,
		os             = ODIN_OS_STRING,
		arch           = ODIN_ARCH_STRING,
		iterations     = n,
		benchmarks     = entries[:],
	}
	code = worse_exit_code(code, _print_and_gate_instructions(report, opts))
	for path in ([]string{opts.json_path, opts.save_baseline}) {
		if path == "" {
			continue
		}
		data, marshal_err := json.marshal(report, {pretty = true}, context.temp_allocator)
		if marshal_err != nil {
			fmt.eprintfln("obench: could not write '%s' (%v)", path, marshal_err)
			code = worse_exit_code(code, EXIT_FAILURE)
			continue
		}
		if err := os.write_entire_file(path, data); err != nil {
			fmt.eprintfln("obench: could not write '%s' (%v)", path, err)
			code = worse_exit_code(code, EXIT_FAILURE)
		}
	}
	return code
}

// Instructions Cachegrind counts for one run of `exe` with `iterations` of benchmark `name`.
@(private = "file")
_cachegrind_count :: proc(exe, name: string, iterations: int) -> (count: u64, ok: bool) {
	cmd := []string {
		"valgrind",
		"--tool=cachegrind",
		"--cache-sim=no",
		"--cachegrind-out-file=/dev/null",
		exe,
		"--exact",
		name,
		"--count-iterations",
		fmt.tprintf("%d", iterations),
	}
	state, _, stderr, err := os.process_exec({command = cmd}, context.temp_allocator)
	if err != nil || !state.exited || state.exit_code != 0 {
		fmt.eprintfln("obench: %s failed under Cachegrind:\n%s", name, string(stderr))
		return 0, false
	}
	// "==1234== I refs:        115,957"
	text := string(stderr)
	for line in strings.split_lines_iterator(&text) {
		_, found, rest := strings.partition(line, "I refs:")
		if found == "" {
			continue
		}
		digits, _ := strings.remove_all(strings.trim_space(rest), ",", context.temp_allocator)
		return strconv.parse_u64(digits)
	}
	fmt.eprintfln("obench: no 'I refs' line in Cachegrind's output for %s", name)
	return 0, false
}

// Prints the counts, compared with `--baseline` when given, and returns the exit status the
// comparison asks for.
@(private = "file")
_print_and_gate_instructions :: proc(report: Instruction_Report, opts: CLI_Options) -> int {
	baseline: map[string]f64
	compared := false
	code := 0
	gate := opts.fail_on_regression
	if opts.load_baseline != "" {
		base, read_code := read_instruction_baseline(opts.load_baseline)
		switch {
		case read_code != EXIT_SUCCESS:
			code = read_code
		case base.optimization != report.optimization ||
		     base.os != report.os ||
		     base.arch != report.arch:
			fmt.eprintfln(
				"obench: warning: baseline '%s' was built with -o:%s on %s/%s and this run with -o:%s on %s/%s, so its counts can't be compared",
				opts.load_baseline,
				base.optimization,
				base.os,
				base.arch,
				report.optimization,
				report.os,
				report.arch,
			)
			code = EXIT_BASELINE
		case:
			baseline = make(map[string]f64, context.temp_allocator)
			for e in base.benchmarks {
				baseline[fmt.tprintf("%s\x00%s", e.suite_name, e.full_name)] =
					e.instructions_per_op
			}
			compared = true
		}
	}

	width := len("benchmark")
	for e in report.benchmarks {
		width = max(width, len(e.suite_name) + 1 + len(e.full_name))
	}
	fmt.printfln(
		"\nobench: instructions per operation under Cachegrind (%d and %d iterations)",
		report.iterations,
		2 * report.iterations,
	)
	fmt.printfln(
		"%-*s │ %15s%s",
		width,
		"benchmark",
		"instructions/op",
		" │ vs baseline" if compared else "",
	)
	matched, regressions := 0, 0
	for e in report.benchmarks {
		name := fmt.tprintf("%s/%s", e.suite_name, e.full_name)
		change := ""
		if compared {
			if old, found := baseline[fmt.tprintf("%s\x00%s", e.suite_name, e.full_name)]; found {
				matched += 1
				delta := (e.instructions_per_op - old) / old * 100 if old > 0 else 0
				change = fmt.tprintf(" │ %+.2f%%", delta)
				if delta > opts.threshold_pct {
					regressions += 1
					change = fmt.tprintf("%s more", change)
				}
			} else {
				change = " │ new"
			}
		}
		fmt.printfln("%-*s │ %15.1f%s", width, name, e.instructions_per_op, change)
	}
	if compared {
		fmt.printfln(
			"%d compared, %d with more than %g%% more instructions",
			matched,
			regressions,
			opts.threshold_pct,
		)
		if matched == 0 && len(report.benchmarks) > 0 {
			fmt.eprintfln(
				"obench: warning: no benchmark is in baseline '%s'; nothing was compared",
				opts.load_baseline,
			)
			code = EXIT_BASELINE
		}
	}
	if !gate && code == EXIT_BASELINE {
		code = 0 // Without a gate a baseline that can't be compared is only a warning.
	}
	if gate && code == 0 && regressions > 0 {
		code = EXIT_FAILURE
	}
	return code
}

/*
Reads a report from `--instructions` to compare with. `code` is `EXIT_FAILURE` when the file
can't be read or isn't JSON, so a misspelled path fails the run, and `EXIT_BASELINE` when it
is another kind of report, which can be saved again.
*/
@(private)
read_instruction_baseline :: proc(path: string) -> (report: Instruction_Report, code: int) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("obench: could not read baseline '%s' (%v)", path, err)
		return {}, EXIT_FAILURE
	}
	if json.unmarshal(data, &report, allocator = context.temp_allocator) != nil {
		fmt.eprintfln("obench: could not read baseline '%s' (not valid JSON)", path)
		return {}, EXIT_FAILURE
	}
	if report.format != INSTRUCTIONS_FORMAT {
		fmt.eprintfln("obench: '%s' isn't a report from --instructions", path)
		return {}, EXIT_BASELINE
	}
	return report, EXIT_SUCCESS
}
