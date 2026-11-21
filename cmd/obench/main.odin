package main

import obench "../../obench"
import "base:runtime"
import "core:encoding/json"
import "core:flags"
import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

// Collection names the CLI defines for generated runner packages.
TARGET_COLLECTION :: "obench_cli_target"
LIB_COLLECTION :: "obench_cli_lib"

EXIT_SUCCESS :: obench.EXIT_SUCCESS
EXIT_FAILURE :: obench.EXIT_FAILURE
EXIT_USAGE :: obench.EXIT_USAGE
EXIT_BASELINE :: obench.EXIT_BASELINE

Subcommand :: enum {
	Run,
	Compare,
	AB,
	Export,
	List,
	Version,
	Help,
}

CLI_Options :: struct {
	subcommand:               Subcommand,
	target_path:              string,
	compare_old:              string, // The first report of each side
	compare_new:              string,
	// Every report of each side; several are combined (`obench compare a1 a2 -- b1 b2`).
	compare_old_files:        []string,
	compare_new_files:        []string,
	// `obench ab`: the two directories, and how many times each one runs.
	ab_baseline:              string,
	ab_candidate:             string,
	rounds:                   int,
	export_format:            Export_Format,
	export_path:              string,
	filter:                   string,
	skip:                     string,
	exact:                    string,
	samples:                  int,
	warmup_ms:                int,
	max_time:                 string, // As given; parse_cli_args checked it parses
	min_sample_time:          string,
	batch_size:               int,
	test_mode:                bool,
	quiet:                    bool,
	counters:                 bool,
	instructions:             bool,
	count:                    int, // Processes per package (`--count`), 1 by default
	list_json:                bool,
	opt_mode:                 string,
	microarch:                string,
	no_bounds_check:          bool,
	ols:                      bool,
	collections:              [dynamic]string,
	defines:                  [dynamic]string,
	extra_linker_flags:       [dynamic]string,
	custom_attributes:        [dynamic]string,
	save_baseline:            string,
	load_baseline:            string,
	json_path:                string,
	md_path:                  string,
	csv_path:                 string,
	html_path:                string,
	spall_path:               string,
	machine:                  string,
	pin_cpu:                  int, // -1 when --pin isn't given
	threshold_pct:            f64,
	zero_alloc:               bool,
	untimed_allocs:           bool,
	timed_allocs:             bool,
	fail_on_regression:       bool,
	fail_on_alloc_regression: bool,
	no_color:                 bool,
	no_histogram:             bool,
}

Discovered_Bench :: struct {
	proc_name:  string,
	group_name: string,
	bench_name: string,
	zero_alloc: bool,
	is_private: bool,
	params:     [dynamic]int,
	threads:    [dynamic]int,
	file_path:  string,
	line:       int,
	problems:   [dynamic]string, // Malformed annotations; the package can't run
	warnings:   [dynamic]string, // Unknown annotations
}

Discovered_Package :: struct {
	dir_path:       string, // absolute
	pkg_name:       string,
	has_main:       bool,
	has_bench_file: bool, // contains a `*_bench.odin` file
	lib_import:     string, // obench import path as written (without quotes); "" if unknown
	benches:        [dynamic]Discovered_Bench,
	warnings:       [dynamic]string, // Annotations that no benchmark reads
}

print_usage :: proc() {
	fmt.printf(
		`obench %s
Allocation-aware micro-benchmarking for Odin.

USAGE:
  obench [run] [dir] [options]          Discover and run benchmarks under dir (default: .)
  obench list [dir] [--json]            List discovered benchmarks without running them
  obench compare <old.json> <new.json>  Compare two JSON reports in benchstat style
  obench compare <old.json>... -- <new.json>...
                                        Compare several reports per side, combined
  obench ab <baseline dir> <candidate dir> [--rounds 6]
                                        Build both, run them alternately in random order,
                                        and compare the two sides on this machine
  obench export --format <format> <report.json>
                                        Convert a JSON report for other tools: bmf (Bencher),
                                        gab (github-action-benchmark), gbench (Google
                                        Benchmark), or jsonl (one line per benchmark)
  obench version | help

DISCOVERY:
  Every package under dir (searched recursively, hidden directories and symlinks skipped)
  that defines 'bench_<name> :: proc(b: ^obench.Bencher)' procedures is built into a
  temporary runner. Files for other platforms (_windows.odin, #+build linux), #+ignore files,
  and #+test files are left out, as 'odin build' does. Packages with their own main() run
  as-is if they define benchmarks or a *_bench.odin file. Nothing is written into your source
  directories.

  bench_<group>__<name>          Group related benchmarks (shared params, speedup column)
  // @group(name)                Set the group explicitly
  // @params(8, 64, 512)         Run the group once per parameter; >= 3 enables Big-O fitting
  // @threads(1, 2, 4)           Run the group once per thread count (use run_parallel)
  // @zero_alloc                 Fail if the measured loop allocates on the heap
  Annotations go on comment lines of their own, directly above the procedure (no blank
  line); several may share a line.

RUN OPTIONS:
  -f, --filter <pattern>         Run only benchmarks whose full name contains the pattern, as
                                 plain text or as a regular expression
      --skip <pattern>           Skip benchmarks whose full name contains the pattern
      --exact <name>             Run only the benchmark with exactly this full name
  -n, --samples <count>          Samples per benchmark (default: 50)
  -w, --warmup <ms>              Warmup per benchmark in milliseconds (default: 40)
      --max-time <duration>      Sampling time budget per benchmark, like 200ms (default: 1200ms)
      --min-sample-time <dur>    Shortest time of one sample, like 500us (default: 1ms)
      --batch-size <count>       Iterations per sample, instead of calibrating them
      --test                     Run every benchmark once with one iteration and every check,
                                 without measuring it (no baseline)
  -q, --quiet                    Print only problems and the summary line
      --counters                 Linux: instructions, IPC, branch and cache misses per op,
                                 where the kernel allows perf_event_open
      --count <processes>        Run every package in this many processes and compare their
                                 medians (default: 1); see "Repeating runs" in the docs
      --instructions             Count instructions per op exactly under Valgrind's
                                 Cachegrind (Linux), with --batch-size iterations (default
                                 100) and twice that; --json, --save-baseline, --baseline,
                                 --threshold and --fail-on-regression work on the counts, and
                                 the other gates, checks and report files are refused
      --zero-alloc               Treat every benchmark as @zero_alloc
      --untimed-allocs           Count allocations in one untimed batch after sampling (default)
      --timed-allocs             Count allocations in every timed sample, which adds the
                                 counting to the time of benchmarks that allocate
      --baseline <file.json>     Compare against a saved report (each package with its own suite)
      --save-baseline <file>     Save results as a JSON report (alias of --json)
      --threshold <pct>          Minimum median change counted as significant (default: 2.0)
      --fail-on-regression       Exit with status 1 if a benchmark regressed significantly,
                                 and with 3 if the baseline holds none of a suite's
                                 benchmarks, was built with another -o mode, OS, arch,
                                 -microarch, or bounds-check setting, or counted allocations
                                 the other way (see --timed-allocs)
      --fail-on-alloc-regression Exit with status 1 if a benchmark allocates more per operation
                                 (heap or temp, count or bytes) than in the baseline, and with
                                 3 if the baseline holds none of a suite's benchmarks
      --json <file>              Write a JSON report (with compare: the comparison as JSON)
      --md <file>                Write a GitHub Markdown report (with compare: the comparison,
                                 for a job summary or a PR comment)
      --csv <file>               Write an RFC 4180 CSV report
      --html <file>              Write a self-contained HTML page with the distributions, the
                                 time-against-N charts, and the baseline drawn over them
      --spall <file>             Write a core:prof/spall trace (one file per package)
      --machine <label>          Name the test machine in the JSON report (machine.label)
      --pin <cpu>                Run the benchmarks on this logical CPU (Linux, Windows)
      --no-color                 Disable ANSI colors. They are also off when NO_COLOR is set
                                 or the output isn't a terminal (FORCE_COLOR=1 keeps them)
      --no-histogram             Hide distribution sparklines

BUILD OPTIONS (forwarded to the Odin compiler):
  -o, --opt <mode>               speed (default), aggressive, size, minimal, none
      --microarch <arch>         -microarch:<arch>, e.g. native
      --no-bounds-check          -no-bounds-check
      --collection <name=path>   -collection:<name>=<path> (repeatable; overrides --ols)
      --ols                      Add collections from the nearest ols.json
      --define <KEY=VAL>         -define:<KEY>=<VAL> (repeatable)
      --extra-linker-flags <val> -extra-linker-flags:<val> (repeatable, space-joined)
      --custom-attribute <name>  -custom-attribute:<name> (repeatable)

The compiler is taken from $ODIN when set, otherwise 'odin' on PATH.
Exit status: 0 success, 1 benchmark/regression/build failure, a baseline file that can't be
read, or an unparsable *_bench.odin package, 2 usage error (also a short flag together with its
long form, like -n and --samples), 3 a baseline that can't be compared with the run (save it
again).
`,
		obench.VERSION,
	)
}

// Command-line flags in the shape `core:flags` fills them (UNIX style: `--flag value`,
// `--flag=value`, `-flag value`). Short aliases are hidden fields merged after parsing.
@(private = "file")
_Cli_Flags :: struct {
	overflow:                 [dynamic]string,
	filter:                   string,
	skip:                     string,
	exact:                    string,
	samples:                  int,
	warmup:                   int,
	max_time:                 string,
	min_sample_time:          string,
	batch_size:               int,
	test:                     bool,
	quiet:                    bool,
	counters:                 bool,
	instructions:             bool,
	count:                    int,
	rounds:                   int,
	opt:                      string,
	microarch:                string,
	no_bounds_check:          bool,
	ols:                      bool,
	collection:               [dynamic]string,
	define:                   [dynamic]string,
	extra_linker_flags:       [dynamic]string,
	custom_attribute:         [dynamic]string,
	save_baseline:            string,
	baseline:                 string,
	threshold:                f64,
	json:                     string,
	md:                       string,
	csv:                      string,
	html:                     string,
	spall:                    string,
	machine:                  string,
	pin:                      int,
	format:                   string,
	zero_alloc:               bool,
	untimed_allocs:           bool,
	timed_allocs:             bool,
	fail_on_regression:       bool,
	fail_on_alloc_regression: bool,
	no_color:                 bool,
	no_histogram:             bool,
	list:                     bool,
	version:                  bool,
	f:                        string `args:"hidden"`,
	n:                        int `args:"hidden"`,
	w:                        int `args:"hidden"`,
	o:                        string `args:"hidden"`,
	v:                        bool `args:"hidden"`,
	q:                        bool `args:"hidden"`,
	list_json:                bool `args:"hidden"`,
}

/*
Parses command-line arguments (without the program name). On failure `err` describes the
problem and the options must not be used. `--help`/`-h` selects the Help subcommand.
*/
parse_cli_args :: proc(
	args: []string,
	allocator := context.allocator,
) -> (
	opts: CLI_Options,
	err: string,
) {
	opts = CLI_Options {
		subcommand    = .Run,
		target_path   = ".",
		opt_mode      = "speed",
		warmup_ms     = -1,
		pin_cpu       = -1,
		threshold_pct = 2.0,
	}

	rest := args
	if len(args) > 0 {
		switch args[0] {
		case "run":
			opts.subcommand = .Run
		case "compare", "diff":
			opts.subcommand = .Compare
		case "ab":
			opts.subcommand = .AB
		case "export":
			opts.subcommand = .Export
		case "list":
			opts.subcommand = .List
		case "version":
			opts.subcommand = .Version
		case "help":
			opts.subcommand = .Help
		}
		if args[0] == "run" ||
		   args[0] == "ab" ||
		   args[0] == "compare" ||
		   args[0] == "diff" ||
		   args[0] == "export" ||
		   args[0] == "list" ||
		   args[0] == "version" ||
		   args[0] == "help" {
			rest = args[1:]
		}
	}

	// `min(int)` marks numeric flags the user didn't pass.
	UNSET :: min(int)
	f := _Cli_Flags {
		samples    = UNSET,
		n          = UNSET,
		warmup     = UNSET,
		w          = UNSET,
		batch_size = UNSET,
		pin        = UNSET,
		count      = UNSET,
		rounds     = UNSET,
		threshold  = 2.0,
	}
	// `compare a1.json a2.json -- b1.json b2.json`: the reports after `--` are the new side.
	// Options go before `--`; one after it can't take a separate value.
	has_new_side := false
	if opts.subcommand == .Compare {
		for arg, i in rest {
			if arg != "--" {
				continue
			}
			before := make([dynamic]string, context.temp_allocator)
			after := make([dynamic]string, allocator)
			append(&before, ..rest[:i])
			for a in rest[i + 1:] {
				if strings.has_prefix(a, "-") {
					append(&before, a)
				} else {
					append(&after, a)
				}
			}
			rest = before[:]
			// Owned by `opts` from here, so `destroy_cli_options` frees it on every path.
			opts.compare_new_files = after[:]
			has_new_side = true
			break
		}
	}
	// `list --json` prints the list as JSON; elsewhere `--json` takes a file name.
	if opts.subcommand == .List {
		renamed := make([]string, len(rest), context.temp_allocator)
		for arg, i in rest {
			renamed[i] = "--list-json" if arg == "--json" || arg == "-json" else arg
		}
		rest = renamed
	}
	parse_err := flags.parse(&f, rest, .Unix, allocator = allocator)
	opts.collections = f.collection
	opts.defines = f.define
	opts.extra_linker_flags = f.extra_linker_flags
	opts.custom_attributes = f.custom_attribute
	defer delete(f.overflow)

	switch e in parse_err {
	case nil:
	case flags.Help_Request:
		opts.subcommand = .Help
		return opts, ""
	case flags.Parse_Error:
		return opts, e.message
	case flags.Validation_Error:
		return opts, e.message
	case flags.Open_File_Error:
		return opts, fmt.tprintf("could not open '%s'", e.filename)
	}

	// Merge the short aliases. core:flags doesn't keep the order of the arguments, so a short
	// alias and its long form together are ambiguous.
	switch {
	case f.f != "" && f.filter != "":
		return opts, "give either -f or --filter, not both"
	case f.n != UNSET && f.samples != UNSET:
		return opts, "give either -n or --samples, not both"
	case f.w != UNSET && f.warmup != UNSET:
		return opts, "give either -w or --warmup, not both"
	case f.o != "" && f.opt != "":
		return opts, "give either -o or --opt, not both"
	}
	if f.f != "" {
		f.filter = f.f
	}
	if f.n != UNSET {
		f.samples = f.n
	}
	if f.w != UNSET {
		f.warmup = f.w
	}
	if f.o != "" {
		f.opt = f.o
	}
	if f.v || f.version {
		opts.subcommand = .Version
	}
	if f.list {
		opts.subcommand = .List
	}

	switch {
	case f.samples != UNSET && f.samples <= 0:
		return opts, "--samples expects a positive integer"
	case f.warmup != UNSET && f.warmup < 0:
		return opts, "--warmup expects a non-negative integer (milliseconds)"
	case f.threshold <= 0:
		return opts, "--threshold expects a positive number"
	case f.pin != UNSET && f.pin < 0:
		return opts, "--pin expects a CPU number, 0 or more"
	case f.rounds != UNSET && f.rounds < 2:
		return opts, "--rounds expects 2 or more"
	case f.count != UNSET && f.count < 1:
		return opts, "--count expects a positive number of processes"
	case f.count > 1 && (f.md != "" || f.csv != "" || f.spall != ""):
		return opts,
			"--count combines the JSON reports of its processes, so it writes --json, --save-baseline and --html but not --md, --csv or --spall"
	case f.count > 1 && (f.test || f.instructions):
		return opts,
			"--count repeats a measured run, so it can't be used with --test or --instructions"
	case f.instructions &&
	     (f.fail_on_alloc_regression ||
			     f.zero_alloc ||
			     f.test ||
			     f.md != "" ||
			     f.csv != "" ||
			     f.html != "" ||
			     f.spall != ""):
		return opts,
			"--instructions only counts instructions, so it can't be used with --fail-on-alloc-regression, --zero-alloc, --test, --md, --csv, --html or --spall"
	case f.untimed_allocs && f.timed_allocs:
		return opts, "--untimed-allocs and --timed-allocs can't be used together"
	case f.batch_size != UNSET && f.batch_size <= 0:
		return opts, "--batch-size expects a positive integer"
	case f.test &&
	     (f.baseline != "" ||
			     f.save_baseline != "" ||
			     f.fail_on_regression ||
			     f.fail_on_alloc_regression):
		return opts,
			"--test runs every benchmark once without measuring it, so it can't be used with --baseline, --save-baseline, --fail-on-regression, or --fail-on-alloc-regression"
	}
	for d in ([]struct {
			flag, value: string,
		}{{"--max-time", f.max_time}, {"--min-sample-time", f.min_sample_time}}) {
		if d.value == "" {
			continue
		}
		if dur, ok := obench.parse_duration(d.value); !ok || dur <= 0 {
			return opts, fmt.tprintf(
				"%s expects a duration like 200ms, 500us or 1.5s, got '%s'",
				d.flag,
				d.value,
			)
		}
	}
	if f.opt != "" {
		switch f.opt {
		case "speed", "aggressive", "size", "minimal", "none":
		case:
			return opts, fmt.tprintf(
				"--opt expects speed, aggressive, size, minimal, or none, got '%s'",
				f.opt,
			)
		}
		opts.opt_mode = f.opt
	}
	for c in f.collection {
		if !strings.contains(c, "=") {
			return opts, fmt.tprintf("--collection expects name=path, got '%s'", c)
		}
	}
	for d in f.define {
		if !strings.contains(d, "=") {
			return opts, fmt.tprintf("--define expects KEY=VALUE, got '%s'", d)
		}
	}
	for ef in f.extra_linker_flags {
		if strings.trim_space(ef) == "" {
			return opts, "--extra-linker-flags expects a non-empty string"
		}
	}
	for ca in f.custom_attribute {
		if strings.trim_space(ca) == "" {
			return opts, "--custom-attribute expects a non-empty name"
		}
	}

	opts.filter = f.filter
	opts.skip = f.skip
	opts.exact = f.exact
	opts.max_time = f.max_time
	opts.min_sample_time = f.min_sample_time
	opts.batch_size = f.batch_size if f.batch_size != UNSET else 0
	opts.test_mode = f.test
	opts.quiet = f.quiet || f.q
	opts.counters = f.counters
	opts.instructions = f.instructions
	opts.count = f.count if f.count != UNSET else 1
	opts.rounds = f.rounds if f.rounds != UNSET else DEFAULT_AB_ROUNDS
	opts.list_json = f.list_json
	opts.samples = f.samples if f.samples != UNSET else 0
	opts.warmup_ms = f.warmup if f.warmup != UNSET else -1
	opts.threshold_pct = f.threshold
	opts.microarch = f.microarch
	opts.no_bounds_check = f.no_bounds_check
	opts.ols = f.ols
	opts.save_baseline = f.save_baseline
	opts.load_baseline = f.baseline
	opts.json_path = f.json
	opts.md_path = f.md
	opts.csv_path = f.csv
	opts.html_path = f.html
	opts.spall_path = f.spall
	opts.machine = f.machine
	opts.pin_cpu = f.pin if f.pin != UNSET else -1
	opts.zero_alloc = f.zero_alloc
	opts.untimed_allocs = f.untimed_allocs
	opts.timed_allocs = f.timed_allocs
	opts.fail_on_regression = f.fail_on_regression
	opts.fail_on_alloc_regression = f.fail_on_alloc_regression
	opts.no_color = f.no_color
	opts.no_histogram = f.no_histogram

	positionals := f.overflow[:]
	switch opts.subcommand {
	case .Compare:
		switch {
		case has_new_side:
			if len(positionals) == 0 || len(opts.compare_new_files) == 0 {
				return opts,
					"compare expects reports on both sides of --: obench compare <old.json>... -- <new.json>..."
			}
			opts.compare_old_files = slice.clone(positionals, allocator)
		case len(positionals) != 2:
			return opts,
				"compare expects two JSON files, or several on each side of --: obench compare <old.json> <new.json>"
		case:
			opts.compare_old_files = slice.clone(positionals[:1], allocator)
			opts.compare_new_files = slice.clone(positionals[1:], allocator)
		}
		opts.compare_old = opts.compare_old_files[0]
		opts.compare_new = opts.compare_new_files[0]
	case .AB:
		if len(positionals) != 2 {
			return opts, "ab expects two directories: obench ab <baseline dir> <candidate dir>"
		}
		opts.ab_baseline = positionals[0]
		opts.ab_candidate = positionals[1]
	case .Export:
		format, ok := parse_export_format(f.format)
		if !ok {
			return opts,
				"export expects --format bmf, gab, gbench or jsonl: obench export --format bmf <report.json>"
		}
		if len(positionals) != 1 {
			return opts, "export expects one JSON report: obench export --format bmf <report.json>"
		}
		opts.export_format = format
		opts.export_path = positionals[0]
	case .Run, .List:
		if len(positionals) > 1 {
			return opts, fmt.tprintf("expected at most one directory, got %d", len(positionals))
		}
		if len(positionals) == 1 {
			opts.target_path = positionals[0]
		}
	case .Help, .Version:
	}
	return opts, ""
}

destroy_cli_options :: proc(opts: ^CLI_Options) {
	delete(opts.compare_old_files)
	delete(opts.compare_new_files)
	delete(opts.collections)
	delete(opts.defines)
	delete(opts.extra_linker_flags)
	delete(opts.custom_attributes)
}

/*
Annotations found in the doc comment above a benchmark procedure. `problems` and `warnings`
hold messages that start with the comment's `file(line)`.
*/
Doc_Annotations :: struct {
	group_name: string, // Points into the comment, or is the default group
	zero_alloc: bool,
	params:     [dynamic]int,
	threads:    [dynamic]int,
	problems:   [dynamic]string,
	warnings:   [dynamic]string,
}

// Parses the comma-separated integers of `@params(...)` or `@threads(...)` into `out`.
@(private = "file")
_parse_int_list :: proc(
	args: string,
	name: string,
	positive_only: bool,
	where_: string,
	out: ^Doc_Annotations,
	values: ^[dynamic]int,
	allocator: runtime.Allocator,
) {
	if strings.trim_space(args) == "" {
		append(
			&out.problems,
			fmt.aprintf("%s: @%s() lists no values", where_, name, allocator = allocator),
		)
		return
	}
	rest := args
	for part in strings.split_iterator(&rest, ",") {
		text := strings.trim_space(part)
		v, ok := strconv.parse_int(text)
		switch {
		case !ok:
			append(
				&out.problems,
				fmt.aprintf(
					"%s: @%s: '%s' is not an integer",
					where_,
					name,
					text,
					allocator = allocator,
				),
			)
		case positive_only && v <= 0:
			append(
				&out.problems,
				fmt.aprintf(
					"%s: @%s: %d is not a positive count",
					where_,
					name,
					v,
					allocator = allocator,
				),
			)
		case:
			append(values, v)
		}
	}
}

// Parses one comment line that starts with `@`: one or more annotations separated by spaces.
@(private = "file")
_parse_annotation_line :: proc(
	line: string,
	where_: string,
	out: ^Doc_Annotations,
	allocator: runtime.Allocator,
) {
	rest := line
	for rest != "" {
		if rest[0] != '@' {
			append(
				&out.warnings,
				fmt.aprintf(
					"%s: ignored text after the annotations: '%s'",
					where_,
					rest,
					allocator = allocator,
				),
			)
			return
		}
		name_end := 1
		for name_end < len(rest) {
			c := rest[name_end]
			if c != '_' && (c < 'a' || c > 'z') && (c < 'A' || c > 'Z') && (c < '0' || c > '9') {
				break
			}
			name_end += 1
		}
		name := rest[1:name_end]
		rest = rest[name_end:]

		args := ""
		has_args := strings.has_prefix(rest, "(")
		if has_args {
			close_idx := strings.index_byte(rest, ')')
			if close_idx < 0 {
				append(
					&out.problems,
					fmt.aprintf(
						"%s: @%s( has no closing ')'",
						where_,
						name,
						allocator = allocator,
					),
				)
				return
			}
			args = rest[1:close_idx]
			rest = rest[close_idx + 1:]
		}

		switch name {
		case "zero_alloc":
			if has_args {
				append(
					&out.problems,
					fmt.aprintf("%s: @zero_alloc takes no values", where_, allocator = allocator),
				)
			}
			out.zero_alloc = true
		case "group":
			group := strings.trim(args, " \t\"'")
			if group == "" {
				append(
					&out.problems,
					fmt.aprintf(
						"%s: @group needs a name, as in @group(name)",
						where_,
						allocator = allocator,
					),
				)
			} else {
				out.group_name = group
			}
		case "params":
			_parse_int_list(args, "params", false, where_, out, &out.params, allocator)
		case "threads":
			_parse_int_list(args, "threads", true, where_, out, &out.threads, allocator)
		case:
			append(
				&out.warnings,
				fmt.aprintf(
					"%s: unknown annotation @%s (obench reads @group, @params, @threads, and @zero_alloc)",
					where_,
					name,
					allocator = allocator,
				),
			)
		}
		rest = strings.trim_left_space(rest)
	}
}

/*
Parses the doc comment above a benchmark procedure for `@zero_alloc`, `@group(...)`,
`@params(...)`, and `@threads(...)`.

Annotations sit on comment lines of their own, and a line may hold several of them. Lines
that don't start with `@` are prose, so a sentence that mentions `@zero_alloc` changes
nothing. A malformed value is a problem, and an unknown `@name` is a warning.
*/
parse_doc_annotations :: proc(
	docs: ^ast.Comment_Group,
	default_group: string,
	allocator := context.allocator,
) -> (
	res: Doc_Annotations,
) {
	res.group_name = default_group
	res.params = make([dynamic]int, allocator)
	res.threads = make([dynamic]int, allocator)
	res.problems = make([dynamic]string, allocator)
	res.warnings = make([dynamic]string, allocator)
	if docs == nil {
		return
	}

	for tok in docs.list {
		body := tok.text
		switch {
		case strings.has_prefix(body, "//"):
			body = body[2:]
		case strings.has_prefix(body, "/*"):
			body = strings.trim_suffix(body[2:], "*/")
		}
		line_no := tok.pos.line
		for line in strings.split_lines_iterator(&body) {
			text := strings.trim_space(line)
			if strings.has_prefix(text, "*") && !strings.has_prefix(text, "*/") {
				text = strings.trim_left_space(text[1:])
			}
			if strings.has_prefix(text, "@") {
				where_ := fmt.tprintf("%s(%d)", tok.pos.file, line_no)
				_parse_annotation_line(text, where_, &res, allocator)
			}
			line_no += 1
		}
	}
	return
}

/*
Appends a warning for every obench annotation line (`@group`, `@params`, `@threads`,
`@zero_alloc`) in a comment group of `file` that is no declaration's doc comment. Such a
comment usually sits above a benchmark with a blank line in between, so obench never sees it.
*/
@(private)
detached_annotation_warnings :: proc(
	file: ^ast.File,
	out: ^[dynamic]string,
	allocator := context.allocator,
) {
	attached := make(map[^ast.Comment_Group]bool, context.temp_allocator)
	if file.docs != nil {
		attached[file.docs] = true
	}
	for decl in file.decls {
		if vd, ok := decl.derived.(^ast.Value_Decl); ok && vd.docs != nil {
			attached[vd.docs] = true
		}
	}
	for group in file.comments {
		if group in attached {
			continue
		}
		for tok in group.list {
			if !strings.has_prefix(tok.text, "//") {
				continue
			}
			text := strings.trim_space(tok.text[2:])
			for name in ([?]string{"@zero_alloc", "@group", "@params", "@threads"}) {
				if !strings.has_prefix(text, name) {
					continue
				}
				next := len(name) < len(text) ? text[len(name)] : ' '
				if next == ' ' || next == '\t' || next == '(' {
					append(
						out,
						fmt.aprintf(
							"%s(%d): '%s' is not attached to a benchmark and is ignored (remove the blank line between the comment and the procedure)",
							tok.pos.file,
							tok.pos.line,
							name,
							allocator = allocator,
						),
					)
					break
				}
			}
		}
	}
}

/*
Reports whether `lit` has the benchmark signature `proc(b: ^Bencher)` or
`proc(b: ^pkg.Bencher)`. On success `pkg_alias` is the package qualifier ("" if none).
*/
bench_signature :: proc(lit: ^ast.Proc_Lit) -> (pkg_alias: string, ok: bool) {
	if lit == nil || lit.type == nil || lit.type.generic {
		return "", false
	}
	pt := lit.type
	if pt.params == nil || len(pt.params.list) != 1 {
		return "", false
	}
	if pt.results != nil && len(pt.results.list) > 0 {
		return "", false
	}
	field := pt.params.list[0]
	if len(field.names) != 1 || field.type == nil {
		return "", false
	}
	ptr, is_ptr := field.type.derived.(^ast.Pointer_Type)
	if !is_ptr || ptr.elem == nil {
		return "", false
	}
	#partial switch e in ptr.elem.derived {
	case ^ast.Ident:
		return "", e.name == "Bencher"
	case ^ast.Selector_Expr:
		if e.field == nil || e.field.name != "Bencher" {
			return "", false
		}
		if id, is_id := e.expr.derived.(^ast.Ident); is_id {
			return id.name, true
		}
	}
	return "", false
}

@(private = "file")
_has_private_attribute :: proc(attrs: [dynamic]^ast.Attribute) -> bool {
	for attr in attrs {
		for elem in attr.elems {
			#partial switch e in elem.derived {
			case ^ast.Ident:
				if e.name == "private" {
					return true
				}
			case ^ast.Field_Value:
				if id, ok := e.field.derived.(^ast.Ident); ok && id.name == "private" {
					return true
				}
			}
		}
	}
	return false
}

// The name an import is referred to by: its explicit alias or the last path element.
@(private = "file")
_import_alias :: proc(imp: ^ast.Import_Decl) -> (alias: string, path: string) {
	path = strings.trim(imp.fullpath, "\"`")
	if imp.name.text != "" {
		return imp.name.text, path
	}
	base := path
	if colon := strings.last_index_byte(base, ':'); colon >= 0 {
		base = base[colon + 1:]
	}
	base = strings.trim_right(base, "/")
	if slash := strings.last_index_byte(base, '/'); slash >= 0 {
		base = base[slash + 1:]
	}
	return base, path
}

@(private = "file")
_silent_parser_handler :: proc(pos: tokenizer.Pos, msg: string, args: ..any) {}

Discover_Status :: enum {
	Benchmark_Package,
	Not_Benchmark,
	Parse_Error, // The directory has *_bench.odin files but could not be parsed.
	Obench_Library, // The obench library itself (declares `Bencher :: struct`).
}

/*
Reports whether the compiler leaves out the file `name` when building for this OS and
architecture: `.`-prefixed files and `_<os>`, `_<arch>`, `_<os>_<arch>` suffixes.
*/
@(private)
excluded_by_file_name :: proc(name: string) -> bool {
	if strings.has_prefix(name, ".") {
		return true
	}
	stem := strings.trim_suffix(name, ".odin")
	last_us := strings.last_index_byte(stem, '_')
	if last_us < 0 {
		return false
	}
	last := stem[last_us + 1:]
	rest := stem[:last_us]
	second := rest[strings.last_index_byte(rest, '_') + 1:] // `windows` in `windows_amd64`

	os1, _ := parser.get_build_os_from_string(last)
	arch1 := parser.get_build_arch_from_string(last)
	os2, _ := parser.get_build_os_from_string(second)
	arch2 := parser.get_build_arch_from_string(second)
	switch {
	case os1 != .Unknown && arch2 != .Unknown:
		return os1 != ODIN_OS || arch2 != ODIN_ARCH
	case os2 != .Unknown && arch1 != .Unknown:
		return os2 != ODIN_OS || arch1 != ODIN_ARCH
	case os1 != .Unknown:
		return os1 != ODIN_OS
	case arch1 != .Unknown:
		return arch1 != ODIN_ARCH
	}
	return false
}

/*
Reports whether `file` has a `#+test` tag. The compiler builds such a file only for `odin
test`, and the CLI builds the runner with `odin build`, so the runner can't see what the file
declares. `File_Tags` in `core:odin/parser` has no field for this tag, so it is matched the
way the compiler's `parse_file_tag` does: the text after `#+` starts with `test`.
*/
@(private = "file")
_is_test_only_file :: proc(file: ^ast.File) -> bool {
	for tag in file.tags {
		if strings.has_prefix(tag.text, "#+") &&
		   strings.has_prefix(strings.trim_space(tag.text[2:]), "test") {
			return true
		}
	}
	return false
}

/*
Parses the `.odin` files of the package in `dir` that the compiler would build for this OS
and architecture with `odin build` (file-name suffixes, `#+build` / `#+ignore` tags, and no
`#+test` files). `ok` is false when an included file has a syntax error. Lists the directory
instead of using a glob, so paths with `[` or `]` work.
*/
@(private = "file")
_parse_target_package :: proc(dir: string, p: ^parser.Parser) -> (pkg: ^ast.Package, ok: bool) {
	NO_POS :: tokenizer.Pos{}

	entries, dir_err := os.read_all_directory_by_path(dir, context.allocator)
	if dir_err != nil {
		return nil, false
	}
	names := make([dynamic]string, 0, len(entries))
	for fi in entries {
		if fi.type == .Regular &&
		   strings.has_suffix(fi.name, ".odin") &&
		   !excluded_by_file_name(fi.name) {
			append(&names, fi.name)
		}
	}
	slice.sort(names[:])

	pkg = ast.new(ast.Package, NO_POS, NO_POS)
	pkg.fullpath = dir
	ok = true
	target := parser.Build_Target {
		os   = ODIN_OS,
		arch = ODIN_ARCH,
	}
	for name in names {
		fullpath, _ := filepath.join({dir, name})
		src, src_err := os.read_entire_file(fullpath, context.allocator)
		if src_err != nil {
			return pkg, false
		}
		if strings.trim_space(string(src)) == "" {
			continue
		}
		file := ast.new(ast.File, NO_POS, NO_POS)
		file.pkg = pkg
		file.src = string(src)
		file.fullpath = fullpath
		parsed := parser.parse_file(p, file)
		if !parser.match_build_tags(parser.parse_file_tags(file^), target) ||
		   _is_test_only_file(file) {
			continue
		}
		if !parsed {
			ok = false
		}
		if pkg.name == "" && file.pkg_decl != nil {
			pkg.name = file.pkg_decl.name
		}
		pkg.files[fullpath] = file
	}
	return pkg, ok
}

@(private = "file")
_dir_has_bench_file :: proc(dir: string) -> bool {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return false
	}
	for fi in entries {
		if fi.type == .Regular && strings.has_suffix(fi.name, "_bench.odin") {
			return true
		}
	}
	return false
}

/*
Parses the Odin package in `dir_path` and extracts its benchmark procedures.
*/
discover_package :: proc(
	dir_path: string,
	allocator := context.allocator,
) -> (
	res: Discovered_Package,
	status: Discover_Status,
) {
	abs_dir, abs_err := os.get_absolute_path(dir_path, allocator)
	if abs_err != nil {
		return res, .Not_Benchmark
	}

	// The parser never frees its AST, so parse into an arena that is released on return.
	// Everything kept in `res` is cloned with `allocator`.
	parse_arena := runtime.Arena {
		backing_allocator = context.allocator,
	}
	defer runtime.arena_destroy(&parse_arena)

	p := parser.default_parser()
	p.err = _silent_parser_handler
	p.warn = _silent_parser_handler
	pkg: ^ast.Package
	parsed_ok: bool
	{
		context.allocator = runtime.arena_allocator(&parse_arena)
		pkg, parsed_ok = _parse_target_package(abs_dir, &p)
	}
	if !parsed_ok || pkg == nil || len(pkg.files) == 0 {
		has_bench_file := _dir_has_bench_file(abs_dir)
		delete(abs_dir, allocator)
		return res, has_bench_file ? .Parse_Error : .Not_Benchmark
	}

	res.dir_path = abs_dir
	res.pkg_name = strings.clone(pkg.name, allocator)
	res.benches = make([dynamic]Discovered_Bench, allocator)
	res.warnings = make([dynamic]string, allocator)

	file_paths := make([dynamic]string, 0, len(pkg.files), context.temp_allocator)
	for k in pkg.files {
		append(&file_paths, k)
	}
	slice.sort(file_paths[:])

	bencher_alias := ""
	import_paths := make(map[string]string, context.temp_allocator) // alias -> path
	declares_bencher := false

	for fpath in file_paths {
		file := pkg.files[fpath]
		if file == nil {
			continue
		}
		base_name := filepath.base(fpath)
		if strings.has_suffix(base_name, "_test.odin") {
			continue
		}
		if strings.has_suffix(base_name, "_bench.odin") {
			res.has_bench_file = true
		}
		detached_annotation_warnings(file, &res.warnings, allocator)

		file_private := false
		for tag in file.tags {
			if strings.contains(tag.text, "+private") {
				file_private = true
			}
		}

		for imp in file.imports {
			alias, path := _import_alias(imp)
			import_paths[alias] = path
		}

		file_stem := filepath.short_stem(base_name)
		file_group := strings.trim_suffix(file_stem, "_bench")
		if file_group == "" || file_group == "main" {
			file_group = "default"
		}

		for decl in file.decls {
			vd, is_vd := decl.derived.(^ast.Value_Decl)
			if !is_vd || vd.is_mutable || len(vd.names) == 0 || len(vd.values) == 0 {
				continue
			}
			ident, is_ident := vd.names[0].derived.(^ast.Ident)
			if !is_ident {
				continue
			}
			if _, is_struct := vd.values[0].derived.(^ast.Struct_Type);
			   is_struct && ident.name == "Bencher" {
				declares_bencher = true
				continue
			}
			lit, is_proc := vd.values[0].derived.(^ast.Proc_Lit)
			if !is_proc {
				continue
			}

			if ident.name == "main" {
				res.has_main = true
				continue
			}
			if !strings.has_prefix(ident.name, "bench_") || len(ident.name) <= len("bench_") {
				continue
			}
			alias, is_bench := bench_signature(lit)
			if !is_bench {
				continue
			}
			if alias != "" {
				bencher_alias = alias
			}

			raw_rest := ident.name[len("bench_"):]
			default_grp := file_group
			b_name := raw_rest
			if dbl_idx := strings.index(raw_rest, "__");
			   dbl_idx > 0 && dbl_idx + 2 < len(raw_rest) {
				default_grp = raw_rest[:dbl_idx]
				b_name = raw_rest[dbl_idx + 2:]
			}

			notes := parse_doc_annotations(vd.docs, default_grp, allocator)
			append(
				&res.benches,
				Discovered_Bench {
					proc_name = strings.clone(ident.name, allocator),
					group_name = strings.clone(notes.group_name, allocator),
					bench_name = strings.clone(b_name, allocator),
					zero_alloc = notes.zero_alloc,
					is_private = file_private || _has_private_attribute(vd.attributes),
					params = notes.params,
					threads = notes.threads,
					file_path = strings.clone(vd.pos.file, allocator),
					line = vd.pos.line,
					problems = notes.problems,
					warnings = notes.warnings,
				},
			)
		}
	}

	if bencher_alias != "" {
		if path, found := import_paths[bencher_alias]; found {
			res.lib_import = strings.clone(path, allocator)
		}
	}

	if declares_bencher {
		destroy_discovered_package(&res, allocator)
		return {}, .Obench_Library
	}

	is_benchmark_package := len(res.benches) > 0 || (res.has_main && res.has_bench_file)
	if !is_benchmark_package {
		// A broken *_bench.odin file can hide its benchmarks from the parser.
		syntax_errors := 0
		for _, file in pkg.files {
			syntax_errors += file.syntax_error_count
		}
		skip_status :=
			syntax_errors > 0 && res.has_bench_file ? Discover_Status.Parse_Error : Discover_Status.Not_Benchmark
		destroy_discovered_package(&res, allocator)
		return {}, skip_status
	}
	if res.has_main {
		// Its own main registers the benchmarks; doc comments mean nothing to it.
		for msg in res.warnings {
			delete(msg, allocator)
		}
		clear(&res.warnings)
	}
	return res, .Benchmark_Package
}

destroy_discovered_package :: proc(pkg: ^Discovered_Package, allocator := context.allocator) {
	delete(pkg.dir_path, allocator)
	delete(pkg.pkg_name, allocator)
	delete(pkg.lib_import, allocator)
	for &b in pkg.benches {
		delete(b.proc_name, allocator)
		delete(b.group_name, allocator)
		delete(b.bench_name, allocator)
		delete(b.file_path, allocator)
		delete(b.params)
		delete(b.threads)
		for msg in b.problems {
			delete(msg, allocator)
		}
		delete(b.problems)
		for msg in b.warnings {
			delete(msg, allocator)
		}
		delete(b.warnings)
	}
	delete(pkg.benches)
	for msg in pkg.warnings {
		delete(msg, allocator)
	}
	delete(pkg.warnings)
	pkg^ = {}
}

/*
Reports whether `dir` is a copy of the obench repository: the library in `obench/` next to
the CLI in `cmd/obench/`. A project that vendors the whole repository has one.
*/
@(private = "file")
_is_obench_checkout :: proc(dir: string) -> bool {
	cli_dir, _ := filepath.join({dir, "cmd", "obench"}, context.temp_allocator)
	lib_dir, _ := filepath.join({dir, "obench"}, context.temp_allocator)
	if !os.is_directory(cli_dir) || !os.is_directory(lib_dir) {
		return false
	}
	pkg, status := discover_package(lib_dir, context.temp_allocator)
	destroy_discovered_package(&pkg, context.temp_allocator)
	return status == .Obench_Library
}

@(private = "file")
_discover_recursive :: proc(
	dir: string,
	is_root: bool,
	out: ^[dynamic]Discovered_Package,
	unparsed: ^int,
	allocator := context.allocator,
) {
	// A copy of the obench repository inside a project: its examples and tests are not the
	// user's benchmarks, unless the user pointed the CLI at the copy itself.
	if !is_root && _is_obench_checkout(dir) {
		return
	}

	pkg, status := discover_package(dir, allocator)
	switch status {
	case .Benchmark_Package:
		append(out, pkg)
	case .Parse_Error:
		unparsed^ += 1
		fmt.eprintfln(
			"obench: error: '%s' has *_bench.odin files but could not be parsed (run 'odin check %s')",
			dir,
			dir,
		)
	case .Obench_Library:
		// A copy of the library package: nothing below it is the user's code, unless the
		// user pointed the CLI at it.
		if !is_root {
			return
		}
	case .Not_Benchmark:
	}

	entries, dir_err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if dir_err != nil {
		return
	}
	sub_paths := make([dynamic]string, 0, len(entries), context.temp_allocator)
	for fi in entries {
		if fi.type == .Directory && !strings.has_prefix(fi.name, ".") {
			sub, _ := filepath.join({dir, fi.name}, context.temp_allocator)
			append(&sub_paths, sub)
		}
	}
	slice.sort(sub_paths[:])
	for sub in sub_paths {
		_discover_recursive(sub, false, out, unparsed, allocator)
	}
}

/*
Discovers every benchmark package in `root_path` and its subdirectories. Hidden and
symlinked directories are skipped (so a link can't make the walk loop), and so are copies of
the obench library or repository below `root_path` (their examples and tests are not the
user's benchmarks). `unparsed` counts directories whose `*_bench.odin` files could not be
parsed; each one is reported on stderr.
*/
discover_all_packages :: proc(
	root_path: string,
	allocator := context.allocator,
) -> (
	packages: [dynamic]Discovered_Package,
	unparsed: int,
) {
	packages = make([dynamic]Discovered_Package, allocator)
	_discover_recursive(root_path, true, &packages, &unparsed, allocator)
	return
}

/*
Checks whether a generated runner can call the package's benchmarks. Returns a list of
human-readable problems (empty when the package can run).
*/
check_package :: proc(pkg: Discovered_Package, allocator := context.temp_allocator) -> []string {
	problems := make([dynamic]string, allocator)
	if pkg.has_main {
		return problems[:]
	}
	if pkg.pkg_name == "main" {
		append(
			&problems,
			fmt.aprintf(
				"package 'main' cannot be imported by the generated runner; rename the package (for example 'package %s_bench') or add a main procedure",
				filepath.base(pkg.dir_path),
				allocator = allocator,
			),
		)
	}
	for &b in pkg.benches {
		for msg in b.problems {
			append(&problems, msg)
		}
		if b.is_private {
			append(
				&problems,
				fmt.aprintf(
					"%s(%d): %s is private; obench calls benchmarks from a generated package, so they must not be @(private)",
					b.file_path,
					b.line,
					b.proc_name,
					allocator = allocator,
				),
			)
		}
	}
	if pkg.lib_import == "" {
		append(
			&problems,
			fmt.aprintf(
				"could not find the import that provides Bencher in package '%s'",
				pkg.pkg_name,
				allocator = allocator,
			),
		)
	}
	return problems[:]
}

/*
Resolved description of how to import obench from a generated runner.
`collection` is "" when the user's import already uses a collection.
*/
Lib_Import :: struct {
	import_path: string,
	collection:  string, // "-collection:..." flag to add, or ""
}

resolve_lib_import :: proc(
	pkg: Discovered_Package,
	allocator := context.temp_allocator,
) -> Lib_Import {
	path := pkg.lib_import
	if strings.contains(path, ":") && !filepath.is_abs(path) {
		// Collection import such as "libs:obench" or "shared:obench"; the user's
		// --collection flags are forwarded, so the same import works.
		return Lib_Import{import_path = path}
	}
	abs := path
	if !filepath.is_abs(path) {
		abs, _ = filepath.join({pkg.dir_path, path}, allocator)
	}
	return Lib_Import {
		import_path = LIB_COLLECTION + ":.",
		collection = fmt.aprintf("-collection:%s=%s", LIB_COLLECTION, abs, allocator = allocator),
	}
}

@(private = "file")
_write_ints :: proc(sb: ^strings.Builder, values: []int) {
	for v, i in values {
		if i > 0 {
			strings.write_string(sb, ", ")
		}
		fmt.sbprintf(sb, "%d", v)
	}
}

/*
Returns the suite name of every package (in the same order): the package name, or, for
packages that share their name with another package under `root`, the package name and the
directory relative to `root`, as in `bench (net/http)`. Reports identify benchmarks by
suite and name, so two suites must not share a name.
*/
suite_names :: proc(
	packages: []Discovered_Package,
	root: string,
	allocator := context.temp_allocator,
) -> []string {
	names := make([]string, len(packages), allocator)
	abs_root, root_err := os.get_absolute_path(root, context.temp_allocator)
	for &pkg, i in packages {
		names[i] = pkg.pkg_name
		shared := 0
		for &other in packages {
			if other.pkg_name == pkg.pkg_name {
				shared += 1
			}
		}
		if shared < 2 {
			continue
		}
		rel := pkg.dir_path
		if root_err == nil {
			if r, rel_err := filepath.rel(abs_root, pkg.dir_path, context.temp_allocator);
			   rel_err == nil {
				rel = r
			}
		}
		rel, _ = strings.replace_all(rel, "\\", "/", context.temp_allocator)
		names[i] = fmt.aprintf("%s (%s)", pkg.pkg_name, rel, allocator = allocator)
	}
	return names
}

/*
Generates the source of a runner package that registers every benchmark of `pkg` and runs
it as a suite named `suite_name`. Warnings about conflicting group annotations are appended
to `warnings`.
*/
generate_runner_source :: proc(
	pkg: Discovered_Package,
	lib_import_path: string,
	suite_name: string,
	warnings: ^[dynamic]string,
	allocator := context.temp_allocator,
) -> string {
	sb := strings.builder_make(allocator)

	strings.write_string(&sb, "// Code generated by obench; DO NOT EDIT.\n")
	strings.write_string(&sb, "package obench_runner\n\n")
	strings.write_string(&sb, "import \"core:os\"\n")
	fmt.sbprintf(&sb, "import obench %q\n", lib_import_path)
	fmt.sbprintf(&sb, "import target %q\n\n", TARGET_COLLECTION + ":.")
	strings.write_string(&sb, "main :: proc() {\n")
	fmt.sbprintf(&sb, "\ts := obench.suite_create(%q)\n", suite_name)
	strings.write_string(&sb, "\tdefer obench.suite_destroy(&s)\n\n")

	groups := make([dynamic]string, context.temp_allocator)
	for &b in pkg.benches {
		if !slice.contains(groups[:], b.group_name) {
			append(&groups, b.group_name)
		}
	}

	for g_name, g_idx in groups {
		fmt.sbprintf(&sb, "\tg%d := obench.group_add(&s, %q)\n", g_idx, g_name)

		params_from := ""
		params: []int
		threads_from := ""
		threads: []int
		for &b in pkg.benches {
			if b.group_name != g_name {
				continue
			}
			if len(b.params) > 0 {
				if params_from == "" {
					params_from = b.proc_name
					params = b.params[:]
				} else if !slice.equal(params, b.params[:]) {
					append(
						warnings,
						fmt.aprintf(
							"group '%s': %s declares @params%v but the group already uses @params%v from %s",
							g_name,
							b.proc_name,
							b.params[:],
							params,
							params_from,
							allocator = allocator,
						),
					)
				}
			}
			if len(b.threads) > 0 {
				if threads_from == "" {
					threads_from = b.proc_name
					threads = b.threads[:]
				} else if !slice.equal(threads, b.threads[:]) {
					append(
						warnings,
						fmt.aprintf(
							"group '%s': %s declares @threads%v but the group already uses @threads%v from %s",
							g_name,
							b.proc_name,
							b.threads[:],
							threads,
							threads_from,
							allocator = allocator,
						),
					)
				}
			}
		}
		if len(params) > 0 {
			fmt.sbprintf(&sb, "\tobench.group_params(g%d, []int{{", g_idx)
			_write_ints(&sb, params)
			strings.write_string(&sb, "})\n")
		}
		if len(threads) > 0 {
			fmt.sbprintf(&sb, "\tobench.group_threads(g%d, []int{{", g_idx)
			_write_ints(&sb, threads)
			strings.write_string(&sb, "})\n")
		}
		for &b in pkg.benches {
			if b.group_name == g_name {
				fmt.sbprintf(
					&sb,
					"\tobench.group_bench(g%d, %q, target.%s, zero_alloc = %v)\n",
					g_idx,
					b.bench_name,
					b.proc_name,
					b.zero_alloc,
				)
			}
		}
		strings.write_string(&sb, "\n")
	}

	strings.write_string(
		&sb,
		"\tif !obench.suite_run(&s) {\n\t\tos.exit(obench.suite_exit_code(&s))\n\t}\n}\n",
	)
	return strings.to_string(sb)
}

// Export paths and baseline matching for one package run. With several packages, each
// package writes to its own file in the work directory and the CLI merges them afterwards.
Package_Outputs :: struct {
	json:                 string,
	baseline:             string, // `--save-baseline` when it differs from `json`
	md:                   string,
	csv:                  string,
	html:                 string,
	spall:                string,
	match_baseline_suite: bool,
}

@(private)
_runtime_args :: proc(
	opts: CLI_Options,
	outputs: Package_Outputs,
	allocator := context.temp_allocator,
) -> []string {
	args := make([dynamic]string, allocator)
	if opts.filter != "" {
		append(&args, "--filter", opts.filter)
	}
	if opts.skip != "" {
		append(&args, "--skip", opts.skip)
	}
	if opts.exact != "" {
		append(&args, "--exact", opts.exact)
	}
	if opts.max_time != "" {
		append(&args, "--max-time", opts.max_time)
	}
	if opts.min_sample_time != "" {
		append(&args, "--min-sample-time", opts.min_sample_time)
	}
	if opts.batch_size > 0 {
		append(&args, "--batch-size", fmt.aprintf("%d", opts.batch_size, allocator = allocator))
	}
	if opts.test_mode {
		append(&args, "--test")
	}
	if opts.quiet {
		append(&args, "-q")
	}
	if opts.counters {
		append(&args, "--counters")
	}
	if opts.samples > 0 {
		append(&args, "--samples", fmt.aprintf("%d", opts.samples, allocator = allocator))
	}
	if opts.warmup_ms >= 0 {
		append(&args, "--warmup", fmt.aprintf("%d", opts.warmup_ms, allocator = allocator))
	}
	append(&args, "--threshold", fmt.aprintf("%f", opts.threshold_pct, allocator = allocator))
	if opts.zero_alloc {
		append(&args, "--zero-alloc")
	}
	if opts.untimed_allocs {
		append(&args, "--untimed-allocs")
	}
	if opts.timed_allocs {
		append(&args, "--timed-allocs")
	}
	if opts.fail_on_regression {
		append(&args, "--fail-on-regression")
	}
	if opts.fail_on_alloc_regression {
		append(&args, "--fail-on-alloc-regression")
	}
	if opts.no_color {
		append(&args, "--no-color")
	}
	if opts.no_histogram {
		append(&args, "--no-histogram")
	}
	if opts.machine != "" {
		append(&args, "--machine", opts.machine)
	}
	if opts.pin_cpu >= 0 {
		append(&args, "--pin", fmt.aprintf("%d", opts.pin_cpu, allocator = allocator))
	}
	if opts.load_baseline != "" {
		append(&args, "--baseline", opts.load_baseline)
		if outputs.match_baseline_suite {
			append(&args, "--match-baseline-suite")
		}
	}
	if outputs.json != "" {
		append(&args, "--json", outputs.json)
	}
	if outputs.baseline != "" {
		append(&args, "--save-baseline", outputs.baseline)
	}
	if outputs.md != "" {
		append(&args, "--md", outputs.md)
	}
	if outputs.html != "" {
		append(&args, "--html", outputs.html)
	}
	if outputs.csv != "" {
		append(&args, "--csv", outputs.csv)
	}
	if outputs.spall != "" {
		append(&args, "--spall", outputs.spall)
	}
	return args[:]
}

@(private = "file")
_odin_executable :: proc() -> string {
	if val := os.get_env("ODIN", context.temp_allocator); val != "" {
		return val
	}
	return "odin"
}

// Runs `cmd` with the CLI's standard streams and returns its exit status, or `EXIT_FAILURE`
// when it couldn't be started or didn't exit normally.
@(private)
_run_process :: proc(cmd: []string) -> int {
	child, start_err := os.process_start(
		os.Process_Desc{command = cmd, stdout = os.stdout, stderr = os.stderr, stdin = os.stdin},
	)
	if start_err != nil {
		fmt.eprintfln("obench: could not start '%s': %v", cmd[0], start_err)
		return EXIT_FAILURE
	}
	state, wait_err := os.process_wait(child)
	// `state.success` only says whether the process crashed, and it is always true on
	// Windows, so a failed run is detected by its exit code.
	if wait_err != nil || !state.exited {
		return EXIT_FAILURE
	}
	return state.exit_code
}

/*
The worse of two exit statuses: a failure (1) beats a baseline that can't be compared (3),
which beats success (0). Any other status, like a crash, counts as a failure.
*/
worse_exit_code :: proc(first, second: int) -> int {
	normal :: proc(code: int) -> int {
		return code if code == 0 || code == EXIT_BASELINE else EXIT_FAILURE
	}
	a, b := normal(first), normal(second)
	switch {
	case a == EXIT_FAILURE || b == EXIT_FAILURE:
		return EXIT_FAILURE
	case a == EXIT_BASELINE || b == EXIT_BASELINE:
		return EXIT_BASELINE
	}
	return 0
}

@(private = "file")
_Ols_Collection :: struct {
	name: string `json:"name"`,
	path: string `json:"path"`,
}

@(private = "file")
_Ols_File :: struct {
	collections: []_Ols_Collection `json:"collections"`,
}

/*
Walks upward from `start_dir` (stopping at the enclosing `.git` root) looking for `ols.json`
and returns `name=abs_path` collection entries from the nearest file found, together with its
path (or `""` if none was found).
*/
discover_ols_collections :: proc(
	start_dir: string,
	allocator := context.temp_allocator,
) -> (
	collections: [dynamic]string,
	found_path: string,
) {
	collections = make([dynamic]string, allocator)
	cur, abs_err := os.get_absolute_path(start_dir, context.temp_allocator)
	if abs_err != nil || cur == "" {
		cur = start_dir
	}
	for cur != "" {
		ols_path, _ := filepath.join({cur, "ols.json"}, context.temp_allocator)
		if os.exists(ols_path) {
			found_path = strings.clone(ols_path, allocator)
			data, read_err := os.read_entire_file(ols_path, context.temp_allocator)
			if read_err != nil {
				fmt.eprintfln("obench: warning: could not read '%s' (%v)", ols_path, read_err)
				break
			}
			doc: _Ols_File
			if json_err := json.unmarshal(data, &doc, allocator = context.temp_allocator);
			   json_err != nil {
				fmt.eprintfln("obench: warning: could not parse '%s' (%v)", ols_path, json_err)
				break
			}
			for col in doc.collections {
				if col.name == "" || col.path == "" {
					continue
				}
				if col.name == "core" ||
				   col.name == "base" ||
				   col.name == "vendor" ||
				   col.name == TARGET_COLLECTION ||
				   col.name == LIB_COLLECTION {
					continue
				}
				resolved := col.path
				if !filepath.is_abs(col.path) {
					resolved, _ = filepath.join({cur, col.path}, context.temp_allocator)
				}
				append(
					&collections,
					fmt.aprintf("%s=%s", col.name, resolved, allocator = allocator),
				)
			}
			break
		}
		git_path, _ := filepath.join({cur, ".git"}, context.temp_allocator)
		if os.exists(git_path) {
			break
		}
		parent := filepath.dir(cur)
		if parent == cur || parent == "." || parent == "" {
			break
		}
		cur = parent
	}
	return collections, found_path
}

@(private = "file")
_collection_name :: proc "contextless" (entry: string) -> string {
	eq := strings.index_byte(entry, '=')
	if eq > 0 {
		return entry[:eq]
	}
	return entry
}

/*
Appends user compiler flags (`--no-bounds-check`, `--microarch`, `--collection`, `--ols`,
`--define`, `--extra-linker-flags`, `--custom-attribute`) to an `odin build` command and
returns any `name=path` collection entries added from `ols.json` together with its path.
*/
append_compiler_flags :: proc(
	cmd: ^[dynamic]string,
	pkg_dir: string,
	opts: CLI_Options,
	allocator := context.temp_allocator,
) -> (
	ols_added: [dynamic]string,
	ols_path: string,
) {
	if opts.no_bounds_check {
		append(cmd, "-no-bounds-check")
	}
	if opts.microarch != "" {
		append(cmd, fmt.aprintf("-microarch:%s", opts.microarch, allocator = allocator))
	}
	seen_collections := make(map[string]bool, context.temp_allocator)
	seen_collections[TARGET_COLLECTION] = true
	seen_collections[LIB_COLLECTION] = true
	seen_collections["core"] = true
	seen_collections["base"] = true
	seen_collections["vendor"] = true
	for col in opts.collections {
		append(cmd, fmt.aprintf("-collection:%s", col, allocator = allocator))
		seen_collections[_collection_name(col)] = true
	}
	ols_added = make([dynamic]string, allocator)
	if opts.ols {
		ols_cols: [dynamic]string
		ols_cols, ols_path = discover_ols_collections(pkg_dir, allocator)
		for col in ols_cols {
			name := _collection_name(col)
			if name not_in seen_collections {
				append(cmd, fmt.aprintf("-collection:%s", col, allocator = allocator))
				append(&ols_added, col)
				seen_collections[name] = true
			}
		}
	}
	for def in opts.defines {
		append(cmd, fmt.aprintf("-define:%s", def, allocator = allocator))
	}
	if len(opts.extra_linker_flags) > 0 {
		joined := strings.join(opts.extra_linker_flags[:], " ", context.temp_allocator)
		append(cmd, fmt.aprintf("-extra-linker-flags:%s", joined, allocator = allocator))
	}
	for ca in opts.custom_attributes {
		append(cmd, fmt.aprintf("-custom-attribute:%s", ca, allocator = allocator))
	}
	return ols_added, ols_path
}

/*
Builds and runs one package and returns its exit status: 0 when it passed, `EXIT_BASELINE`
when only its baseline can't be compared (see `obench.suite_exit_code`), and `EXIT_FAILURE`
for a failed build or run.
`suite_name` names the generated runner's suite; a package with its own main names its own.

The package is built with `odin build` and the executable is started separately, because
the compiler can exit with status 0 without building anything: an unknown `-microarch`
value makes it print the valid ones and stop. Treating that as a passed run would switch a
regression gate off.
*/
run_package :: proc(
	pkg: Discovered_Package,
	index: int,
	suite_name: string,
	work_dir: string,
	opts: CLI_Options,
	outputs: Package_Outputs,
	reported_ols: ^map[string]bool = nil,
) -> int {
	exe_path, built := build_package(pkg, index, suite_name, work_dir, opts, reported_ols)
	if !built {
		return EXIT_FAILURE
	}
	run_cmd := make([dynamic]string, context.temp_allocator)
	append(&run_cmd, exe_path)
	append(&run_cmd, .._runtime_args(opts, outputs))
	return worse_exit_code(0, _run_process(run_cmd[:]))
}

/*
Builds one package's runner (or the package itself, when it has its own main) into
`work_dir` and returns the executable's path. `ok` is false, after saying why, when the
build failed.
*/
build_package :: proc(
	pkg: Discovered_Package,
	index: int,
	suite_name: string,
	work_dir: string,
	opts: CLI_Options,
	reported_ols: ^map[string]bool = nil,
) -> (
	exe_path: string,
	ok: bool,
) {
	exe_name := fmt.tprintf("bench_%d", index)
	when ODIN_OS == .Windows {
		exe_name = fmt.tprintf("bench_%d.exe", index)
	}
	exe_path, _ = filepath.join({work_dir, exe_name}, context.temp_allocator)

	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, _odin_executable(), "build")

	if pkg.has_main {
		append(&cmd, pkg.dir_path)
	} else {
		lib := resolve_lib_import(pkg)
		warnings := make([dynamic]string, context.temp_allocator)
		source := generate_runner_source(pkg, lib.import_path, suite_name, &warnings)
		for w in warnings {
			fmt.eprintfln("obench: warning: %s", w)
		}

		runner_dir, _ := filepath.join(
			{work_dir, fmt.tprintf("runner_%d", index)},
			context.temp_allocator,
		)
		if err := os.make_directory(runner_dir); err != nil {
			fmt.eprintfln("obench: could not create '%s': %v", runner_dir, err)
			return "", false
		}
		runner_file, _ := filepath.join({runner_dir, "main.odin"}, context.temp_allocator)
		if err := os.write_entire_file(runner_file, source); err != nil {
			fmt.eprintfln("obench: could not write '%s': %v", runner_file, err)
			return "", false
		}

		append(&cmd, runner_dir, fmt.tprintf("-collection:%s=%s", TARGET_COLLECTION, pkg.dir_path))
		if lib.collection != "" {
			append(&cmd, lib.collection)
		}
	}

	append(&cmd, fmt.tprintf("-out:%s", exe_path), fmt.tprintf("-o:%s", opts.opt_mode))
	ols_added, ols_path := append_compiler_flags(&cmd, pkg.dir_path, opts)
	{
		collections := make([dynamic]string, context.temp_allocator)
		append(&collections, ..opts.collections[:])
		append(&collections, ..ols_added[:])
		warn_on_library_version_mismatch(pkg.lib_import, pkg.dir_path, collections[:])
	}
	if len(ols_added) > 0 && (reported_ols == nil || ols_path not_in reported_ols^) {
		if reported_ols != nil {
			reported_ols^[ols_path] = true
		}
		shown_ols := ols_path
		if cwd, cwd_err := os.get_working_directory(context.temp_allocator); cwd_err == nil {
			if rel, rel_err := filepath.rel(cwd, ols_path, context.temp_allocator);
			   rel_err == nil && !strings.has_prefix(rel, "..") {
				shown_ols = rel
			}
		}
		fmt.eprintfln(
			"obench: %s: added -collection:%s",
			shown_ols,
			strings.join(ols_added[:], " -collection:", context.temp_allocator),
		)
	}

	if _run_process(cmd[:]) != 0 {
		return "", false
	}
	if !os.exists(exe_path) {
		fmt.eprintfln(
			"obench: '%s build' exited with status 0 but did not build '%s'; its output above says why (an unknown --microarch value does this)",
			cmd[0],
			exe_path,
		)
		return "", false
	}
	return exe_path, true
}

// Path of one package's partial report inside the work directory.
@(private = "file")
_part_path :: proc(work_dir: string, idx: int, ext: string) -> string {
	path, _ := filepath.join(
		{work_dir, fmt.tprintf("part_%d%s", idx, ext)},
		context.temp_allocator,
	)
	return path
}

// Turns `name.ext` into `name.<suffix>.ext`.
@(private = "file")
_suffixed_path :: proc(path: string, suffix: string) -> string {
	ext := filepath.ext(path)
	stem := path[:len(path) - len(ext)]
	return fmt.tprintf("%s.%s%s", stem, suffix, ext)
}

@(private = "file")
_merge_text_reports :: proc(
	inputs: []string,
	output: string,
	skip_repeated_header: bool,
) -> obench.Report_Error {
	sb := strings.builder_make(context.temp_allocator)
	for path, i in inputs {
		data := os.read_entire_file(path, context.temp_allocator) or_return
		text := string(data)
		if skip_repeated_header && i > 0 {
			if nl := strings.index_byte(text, '\n'); nl >= 0 {
				text = text[nl + 1:]
			}
		}
		if !skip_repeated_header && i > 0 {
			strings.write_string(&sb, "\n")
		}
		strings.write_string(&sb, text)
	}
	return os.write_entire_file(output, strings.to_string(sb))
}

@(private = "file")
_merge_markdown :: proc(parts: []string, target: string) -> obench.Report_Error {
	return _merge_text_reports(parts, target, false)
}

@(private = "file")
_merge_csv :: proc(parts: []string, target: string) -> obench.Report_Error {
	return _merge_text_reports(parts, target, true)
}

/*
Reports (and returns true) when two packages wrote a suite with the same name. A merged
report keys benchmarks by suite and name, so a later run could compare one package's
benchmarks with the other's. Generated runners get distinct names from `suite_names`; this
catches packages with their own main.
*/
@(private = "file")
_suites_collide :: proc(parts: []string, part_dirs: []string) -> bool {
	owner := make(map[string]int, context.temp_allocator) // suite name -> part index
	collide := false
	for path, i in parts {
		doc, err := obench.read_json_report(path, context.temp_allocator)
		if err != nil {
			continue // Reported by the merge itself.
		}
		for e in doc.benchmarks {
			first, seen := owner[e.suite_name]
			if !seen {
				owner[e.suite_name] = i
			} else if first >= 0 && first != i {
				fmt.eprintfln(
					"obench: packages '%s' and '%s' both run a suite named '%s'; the merged JSON report could not tell their benchmarks apart, so it was not written. Give the suites different names.",
					part_dirs[first],
					part_dirs[i],
					e.suite_name,
				)
				owner[e.suite_name] = -1
				collide = true
			}
		}
	}
	return collide
}

// Merges per-package report files into `target`. Returns false (after printing why) on failure.
@(private = "file")
_write_merged :: proc(
	target: string,
	parts: []string,
	kind: string,
	merge: proc(parts: []string, target: string) -> obench.Report_Error,
) -> bool {
	if target == "" || len(parts) == 0 {
		return true
	}
	if err := merge(parts, target); err != nil {
		fmt.eprintfln("obench: could not write merged %s report to '%s' (%v)", kind, target, err)
		return false
	}
	return true
}

/*
Runs every discovered package, writes the requested reports, and returns the worst exit
status of them all (see `worse_exit_code`). With several packages, JSON, CSV, and Markdown
reports are merged into the requested file and Spall traces get a per-package suffix.
*/
run_all :: proc(packages: []Discovered_Package, opts: CLI_Options) -> int {
	work_dir, tmp_err := os.make_directory_temp("", "obench-*", context.temp_allocator)
	if tmp_err != nil {
		fmt.eprintfln("obench: could not create a temporary directory: %v", tmp_err)
		return EXIT_FAILURE
	}
	defer os.remove_all(work_dir)

	json_target := opts.json_path != "" ? opts.json_path : opts.save_baseline
	// --save-baseline and --json may name two different files.
	extra_baseline := opts.save_baseline != json_target ? opts.save_baseline : ""
	multi := len(packages) > 1

	json_parts := make([dynamic]string, context.temp_allocator)
	json_part_dirs := make([dynamic]string, context.temp_allocator)
	md_parts := make([dynamic]string, context.temp_allocator)
	csv_parts := make([dynamic]string, context.temp_allocator)
	used_spall_names := make(map[string]bool, context.temp_allocator)
	reported_ols := make(map[string]bool, context.temp_allocator)
	names := suite_names(packages, opts.target_path)

	code := 0
	for &pkg, idx in packages {
		for w in pkg.warnings {
			fmt.eprintfln("obench: warning: %s", w)
		}
		for b in pkg.benches {
			for w in b.warnings {
				fmt.eprintfln("obench: warning: %s", w)
			}
		}
		outputs := Package_Outputs {
			json                 = json_target,
			baseline             = extra_baseline,
			md                   = opts.md_path,
			csv                  = opts.csv_path,
			html                 = opts.html_path,
			spall                = opts.spall_path,
			// Two packages must not compare with each other's numbers in a one-suite baseline.
			match_baseline_suite = multi,
		}
		if multi {
			outputs.baseline = "" // Merged from the JSON parts below.
			// The CLI draws one HTML page for all packages from their merged JSON reports.
			outputs.html = ""
			if outputs.json != "" || opts.html_path != "" {
				outputs.json = _part_path(work_dir, idx, ".json")
			}
			if outputs.md != "" {
				outputs.md = _part_path(work_dir, idx, ".md")
			}
			if outputs.csv != "" {
				outputs.csv = _part_path(work_dir, idx, ".csv")
			}
			if outputs.spall != "" {
				suffix := pkg.pkg_name
				if suffix in used_spall_names {
					suffix = fmt.tprintf("%s_%d", pkg.pkg_name, idx)
				}
				used_spall_names[suffix] = true
				outputs.spall = _suffixed_path(opts.spall_path, suffix)
			}
		}

		problems := check_package(pkg)
		if len(problems) > 0 {
			for p in problems {
				fmt.eprintfln("obench: %s", p)
			}
			code = worse_exit_code(code, EXIT_FAILURE)
			continue
		}

		if opts.count > 1 {
			code = worse_exit_code(
				code,
				run_package_repeated(pkg, idx, names[idx], work_dir, opts, outputs, &reported_ols),
			)
		} else {
			code = worse_exit_code(
				code,
				run_package(pkg, idx, names[idx], work_dir, opts, outputs, &reported_ols),
			)
		}
		if multi {
			if outputs.json != "" && os.exists(outputs.json) {
				append(&json_parts, outputs.json)
				append(&json_part_dirs, pkg.dir_path)
			}
			if outputs.md != "" && os.exists(outputs.md) {
				append(&md_parts, outputs.md)
			}
			if outputs.csv != "" && os.exists(outputs.csv) {
				append(&csv_parts, outputs.csv)
			}
		}
	}

	json_ok := true
	if multi {
		if _suites_collide(json_parts[:], json_part_dirs[:]) {
			json_ok = false
		} else {
			json_ok = _write_merged(json_target, json_parts[:], "JSON", obench.merge_json_reports)
			if json_ok && extra_baseline != "" {
				json_ok = _write_merged(
					extra_baseline,
					json_parts[:],
					"baseline",
					obench.merge_json_reports,
				)
			}
		}
		html_ok := true
		if json_ok && opts.html_path != "" {
			html_ok = write_merged_html(opts, json_target, json_parts[:], work_dir)
		}
		md_ok := _write_merged(opts.md_path, md_parts[:], "Markdown", _merge_markdown)
		csv_ok := _write_merged(opts.csv_path, csv_parts[:], "CSV", _merge_csv)
		if !json_ok || !html_ok || !md_ok || !csv_ok {
			code = worse_exit_code(code, EXIT_FAILURE)
		}
	}
	return code
}

list_packages :: proc(packages: []Discovered_Package) {
	cwd, _ := os.get_working_directory(context.temp_allocator)
	for &pkg in packages {
		shown, rel_err := filepath.rel(cwd, pkg.dir_path, context.temp_allocator)
		if rel_err != nil {
			shown = pkg.dir_path
		}
		if pkg.has_main {
			fmt.printf(
				"Package '%s' (%s): runs its own main(); benchmarks are registered there\n",
				pkg.pkg_name,
				shown,
			)
			continue
		}
		fmt.printf("Package '%s' (%s):\n", pkg.pkg_name, shown)
		for b in pkg.benches {
			z_tag := b.zero_alloc ? " @zero_alloc" : ""
			p_tag := len(b.params) > 0 ? fmt.tprintf(" @params%v", b.params[:]) : ""
			t_tag := len(b.threads) > 0 ? fmt.tprintf(" @threads%v", b.threads[:]) : ""
			fmt.printf(
				"  - %s::%s (%s)%s%s%s\n",
				b.group_name,
				b.bench_name,
				b.proc_name,
				z_tag,
				p_tag,
				t_tag,
			)
		}
		for problem in check_package(pkg) {
			fmt.printf("  ! %s\n", problem)
		}
		for w in pkg.warnings {
			fmt.printf("  warning: %s\n", w)
		}
		for b in pkg.benches {
			for w in b.warnings {
				fmt.printf("  warning: %s\n", w)
			}
		}
	}
}

main :: proc() {
	opts, parse_err := parse_cli_args(os.args[1:] if len(os.args) > 1 else nil)
	defer destroy_cli_options(&opts)
	if parse_err != "" {
		fmt.eprintfln("obench: %s", parse_err)
		fmt.eprintln("Run 'obench help' for usage.")
		os.exit(EXIT_USAGE)
	}

	switch opts.subcommand {
	case .Help:
		print_usage()
		return

	case .Version:
		fmt.printf(
			"obench %s (built with Odin %s, %s/%s)\n",
			obench.VERSION,
			ODIN_VERSION,
			ODIN_OS_STRING,
			ODIN_ARCH_STRING,
		)
		return

	case .Compare:
		if code := run_compare(opts.compare_old_files, opts.compare_new_files, opts); code != 0 {
			os.exit(code)
		}
		return

	case .AB:
		if code := run_ab(opts); code != 0 {
			os.exit(code)
		}
		return

	case .Export:
		doc, err := obench.read_json_report(opts.export_path, context.temp_allocator)
		if err != nil {
			fmt.eprintfln("obench export: could not read '%s' (%v)", opts.export_path, err)
			os.exit(EXIT_FAILURE)
		}
		sb := strings.builder_make(context.temp_allocator)
		if write_export(strings.to_writer(&sb), doc, opts.export_format) != nil {
			fmt.eprintfln("obench export: could not write the %v output", opts.export_format)
			os.exit(EXIT_FAILURE)
		}
		_, _ = os.write_string(os.stdout, strings.to_string(sb))
		return

	case .List, .Run:
	}

	if !os.is_directory(opts.target_path) {
		fmt.eprintfln("obench: '%s' is not a directory", opts.target_path)
		os.exit(EXIT_USAGE)
	}

	set_git_environment(opts.target_path)
	packages, unparsed := discover_all_packages(opts.target_path)
	defer {
		for &pkg in packages {
			destroy_discovered_package(&pkg)
		}
		delete(packages)
	}

	if len(packages) == 0 {
		if unparsed == 0 {
			fmt.eprintfln("obench: no benchmark packages found under '%s'", opts.target_path)
			fmt.eprintln(
				"A benchmark package defines 'bench_<name> :: proc(b: ^obench.Bencher)' procedures.",
			)
		}
		os.exit(EXIT_FAILURE)
	}

	code := 0
	if opts.subcommand == .List {
		if opts.list_json {
			list_packages_json(packages[:])
		} else {
			list_packages(packages[:])
		}
	} else if opts.instructions {
		code = run_instructions(packages[:], opts)
	} else {
		code = run_all(packages[:], opts)
	}
	// The other packages ran, but a benchmark package that doesn't parse must not pass a gate.
	if unparsed > 0 {
		code = worse_exit_code(code, EXIT_FAILURE)
	}
	if code != 0 {
		os.exit(code)
	}
}
