package main

import obench "../../obench"
import "base:runtime"
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

EXIT_FAILURE :: 1
EXIT_USAGE :: 2

Subcommand :: enum {
	Run,
	Compare,
	List,
	Version,
	Help,
}

CLI_Options :: struct {
	subcommand:         Subcommand,
	target_path:        string,
	compare_old:        string,
	compare_new:        string,
	filter:             string,
	samples:            int,
	warmup_ms:          int,
	opt_mode:           string,
	microarch:          string,
	no_bounds_check:    bool,
	collections:        [dynamic]string,
	defines:            [dynamic]string,
	save_baseline:      string,
	load_baseline:      string,
	json_path:          string,
	md_path:            string,
	csv_path:           string,
	spall_path:         string,
	threshold_pct:      f64,
	zero_alloc:         bool,
	fail_on_regression: bool,
	no_color:           bool,
	no_histogram:       bool,
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
}

print_usage :: proc() {
	fmt.printf(
		`obench %s
Allocation-aware micro-benchmarking for Odin.

USAGE:
  obench [run] [dir] [options]          Discover and run benchmarks under dir (default: .)
  obench list [dir]                     List discovered benchmarks without running them
  obench compare <old.json> <new.json>  Compare two JSON reports in benchstat style
  obench version | help

DISCOVERY:
  Every package under dir (searched recursively, hidden directories skipped) that defines
  'bench_<name> :: proc(b: ^obench.Bencher)' procedures is built into a temporary runner.
  Packages with their own main() run as-is if they define benchmarks or a *_bench.odin file.
  Nothing is written into your source directories.

  bench_<group>__<name>          Group related benchmarks (shared params, speedup column)
  // @group(name)                Set the group explicitly
  // @params(8, 64, 512)         Run the group once per parameter; >= 3 enables Big-O fitting
  // @threads(1, 2, 4)           Run the group once per thread count (use run_parallel)
  // @zero_alloc                 Fail if the measured loop allocates on the heap
  Annotations go on comment lines of their own; several may share a line.

RUN OPTIONS:
  -f, --filter <substring>       Run only benchmarks whose full name contains the substring
  -n, --samples <count>          Samples per benchmark (default: 50)
  -w, --warmup <ms>              Warmup per benchmark in milliseconds (default: 40)
      --zero-alloc               Treat every benchmark as @zero_alloc
      --baseline <file.json>     Compare against a saved report
      --save-baseline <file>     Save results as a JSON report (alias of --json)
      --threshold <pct>          Minimum median change counted as significant (default: 2.0)
      --fail-on-regression       Exit with status 1 if a benchmark regressed significantly
      --json <file>              Write a JSON report
      --md <file>                Write a GitHub Markdown report
      --csv <file>               Write an RFC 4180 CSV report
      --spall <file>             Write a core:prof/spall trace (one file per package)
      --no-color                 Disable ANSI colors (NO_COLOR is honored too)
      --no-histogram             Hide distribution sparklines

BUILD OPTIONS (forwarded to the Odin compiler):
  -o, --opt <mode>               speed (default), aggressive, size, minimal, none
      --microarch <arch>         -microarch:<arch>, e.g. native
      --no-bounds-check          -no-bounds-check
      --collection <name=path>   -collection:<name>=<path> (repeatable)
      --define <KEY=VAL>         -define:<KEY>=<VAL> (repeatable)

The compiler is taken from $ODIN when set, otherwise 'odin' on PATH.
Exit status: 0 success, 1 benchmark/regression/build failure, 2 usage error.
`,
		obench.VERSION,
	)
}

// Command-line flags in the shape `core:flags` fills them (UNIX style: `--flag value`,
// `--flag=value`, `-flag value`). Short aliases are hidden fields merged after parsing.
@(private = "file")
_Cli_Flags :: struct {
	overflow:           [dynamic]string,
	filter:             string,
	samples:            int,
	warmup:             int,
	opt:                string,
	microarch:          string,
	no_bounds_check:    bool,
	collection:         [dynamic]string,
	define:             [dynamic]string,
	save_baseline:      string,
	baseline:           string,
	threshold:          f64,
	json:               string,
	md:                 string,
	csv:                string,
	spall:              string,
	zero_alloc:         bool,
	fail_on_regression: bool,
	no_color:           bool,
	no_histogram:       bool,
	list:               bool,
	version:            bool,
	f:                  string `args:"hidden"`,
	n:                  int `args:"hidden"`,
	w:                  int `args:"hidden"`,
	o:                  string `args:"hidden"`,
	v:                  bool `args:"hidden"`,
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
		threshold_pct = 2.0,
	}

	rest := args
	if len(args) > 0 {
		switch args[0] {
		case "run":
			opts.subcommand = .Run
		case "compare", "diff":
			opts.subcommand = .Compare
		case "list":
			opts.subcommand = .List
		case "version":
			opts.subcommand = .Version
		case "help":
			opts.subcommand = .Help
		}
		if args[0] == "run" ||
		   args[0] == "compare" ||
		   args[0] == "diff" ||
		   args[0] == "list" ||
		   args[0] == "version" ||
		   args[0] == "help" {
			rest = args[1:]
		}
	}

	// `min(int)` marks numeric flags the user didn't pass.
	UNSET :: min(int)
	f := _Cli_Flags {
		samples   = UNSET,
		n         = UNSET,
		warmup    = UNSET,
		w         = UNSET,
		threshold = 2.0,
	}
	parse_err := flags.parse(&f, rest, .Unix, allocator = allocator)
	opts.collections = f.collection
	opts.defines = f.define
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

	// Merge the short aliases.
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

	opts.filter = f.filter
	opts.samples = f.samples if f.samples != UNSET else 0
	opts.warmup_ms = f.warmup if f.warmup != UNSET else -1
	opts.threshold_pct = f.threshold
	opts.microarch = f.microarch
	opts.no_bounds_check = f.no_bounds_check
	opts.save_baseline = f.save_baseline
	opts.load_baseline = f.baseline
	opts.json_path = f.json
	opts.md_path = f.md
	opts.csv_path = f.csv
	opts.spall_path = f.spall
	opts.zero_alloc = f.zero_alloc
	opts.fail_on_regression = f.fail_on_regression
	opts.no_color = f.no_color
	opts.no_histogram = f.no_histogram

	positionals := f.overflow[:]
	switch opts.subcommand {
	case .Compare:
		if len(positionals) != 2 {
			return opts,
				"compare expects exactly two JSON files: obench compare <old.json> <new.json>"
		}
		opts.compare_old = positionals[0]
		opts.compare_new = positionals[1]
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
	delete(opts.collections)
	delete(opts.defines)
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
	for part in strings.split(args, ",", context.temp_allocator) {
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
		pkg, parsed_ok = parser.parse_package_from_path(abs_dir, &p)
	}
	if !parsed_ok || pkg == nil || len(pkg.files) == 0 {
		has_bench_file := _dir_has_bench_file(abs_dir)
		delete(abs_dir, allocator)
		return res, has_bench_file ? .Parse_Error : .Not_Benchmark
	}

	res.dir_path = abs_dir
	res.pkg_name = strings.clone(pkg.name, allocator)
	res.benches = make([dynamic]Discovered_Bench, allocator)

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
	return res, .Benchmark_Package
}

destroy_discovered_package :: proc(pkg: ^Discovered_Package, allocator := context.allocator) {
	delete(pkg.dir_path, allocator)
	delete(pkg.pkg_name, allocator)
	delete(pkg.lib_import, allocator)
	for b in pkg.benches {
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
		fmt.eprintfln(
			"obench: warning: skipping '%s': it has *_bench.odin files but could not be parsed (run 'odin check %s')",
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
		_discover_recursive(sub, false, out, allocator)
	}
}

/*
Discovers every benchmark package in `root_path` and its subdirectories. Hidden directories
are skipped, and so are copies of the obench library or repository below `root_path` (their
examples and tests are not the user's benchmarks).
*/
discover_all_packages :: proc(
	root_path: string,
	allocator := context.allocator,
) -> [dynamic]Discovered_Package {
	packages := make([dynamic]Discovered_Package, allocator)
	_discover_recursive(root_path, true, &packages, allocator)
	return packages
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
	for b in pkg.benches {
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
	for pkg, i in packages {
		names[i] = pkg.pkg_name
		shared := 0
		for other in packages {
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
	for b in pkg.benches {
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
		for b in pkg.benches {
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
		for b in pkg.benches {
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

	strings.write_string(&sb, "\tif !obench.suite_run(&s) {\n\t\tos.exit(1)\n\t}\n}\n")
	return strings.to_string(sb)
}

// Export paths for one package run. With several packages, each package writes to its own
// file in the work directory and the CLI merges them afterwards.
Package_Outputs :: struct {
	json:  string,
	md:    string,
	csv:   string,
	spall: string,
}

@(private = "file")
_runtime_args :: proc(
	opts: CLI_Options,
	outputs: Package_Outputs,
	allocator := context.temp_allocator,
) -> []string {
	args := make([dynamic]string, allocator)
	if opts.filter != "" {
		append(&args, "--filter", opts.filter)
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
	if opts.fail_on_regression {
		append(&args, "--fail-on-regression")
	}
	if opts.no_color {
		append(&args, "--no-color")
	}
	if opts.no_histogram {
		append(&args, "--no-histogram")
	}
	if opts.load_baseline != "" {
		append(&args, "--baseline", opts.load_baseline)
	}
	if outputs.json != "" {
		append(&args, "--json", outputs.json)
	}
	if outputs.md != "" {
		append(&args, "--md", outputs.md)
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

// Builds and runs one package. Returns false if the build or the benchmarks failed.
// `suite_name` names the generated runner's suite; a package with its own main names its own.
run_package :: proc(
	pkg: Discovered_Package,
	index: int,
	suite_name: string,
	work_dir: string,
	opts: CLI_Options,
	outputs: Package_Outputs,
) -> bool {
	exe_name := fmt.tprintf("bench_%d", index)
	when ODIN_OS == .Windows {
		exe_name = fmt.tprintf("bench_%d.exe", index)
	}
	exe_path, _ := filepath.join({work_dir, exe_name}, context.temp_allocator)

	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, _odin_executable(), "run")

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
			return false
		}
		runner_file, _ := filepath.join({runner_dir, "main.odin"}, context.temp_allocator)
		if err := os.write_entire_file(runner_file, source); err != nil {
			fmt.eprintfln("obench: could not write '%s': %v", runner_file, err)
			return false
		}

		append(&cmd, runner_dir, fmt.tprintf("-collection:%s=%s", TARGET_COLLECTION, pkg.dir_path))
		if lib.collection != "" {
			append(&cmd, lib.collection)
		}
	}

	append(&cmd, fmt.tprintf("-out:%s", exe_path), fmt.tprintf("-o:%s", opts.opt_mode))
	if opts.no_bounds_check {
		append(&cmd, "-no-bounds-check")
	}
	if opts.microarch != "" {
		append(&cmd, fmt.tprintf("-microarch:%s", opts.microarch))
	}
	for col in opts.collections {
		append(&cmd, fmt.tprintf("-collection:%s", col))
	}
	for def in opts.defines {
		append(&cmd, fmt.tprintf("-define:%s", def))
	}
	append(&cmd, "--")
	append(&cmd, .._runtime_args(opts, outputs))

	child, start_err := os.process_start(
		os.Process_Desc {
			command = cmd[:],
			stdout = os.stdout,
			stderr = os.stderr,
			stdin = os.stdin,
		},
	)
	if start_err != nil {
		fmt.eprintfln("obench: could not start '%s': %v", cmd[0], start_err)
		return false
	}
	state, wait_err := os.process_wait(child)
	// `state.success` only says whether the process crashed, and it is always true on
	// Windows, so a failed run is detected by its exit code.
	return wait_err == nil && state.exited && state.exit_code == 0
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
Runs every discovered package and writes the requested reports. With several packages,
JSON, CSV, and Markdown reports are merged into the requested file and Spall traces get a
per-package suffix.
*/
run_all :: proc(packages: []Discovered_Package, opts: CLI_Options) -> bool {
	work_dir, tmp_err := os.make_directory_temp("", "obench-*", context.temp_allocator)
	if tmp_err != nil {
		fmt.eprintfln("obench: could not create a temporary directory: %v", tmp_err)
		return false
	}
	defer os.remove_all(work_dir)

	json_target := opts.json_path != "" ? opts.json_path : opts.save_baseline
	multi := len(packages) > 1

	json_parts := make([dynamic]string, context.temp_allocator)
	json_part_dirs := make([dynamic]string, context.temp_allocator)
	md_parts := make([dynamic]string, context.temp_allocator)
	csv_parts := make([dynamic]string, context.temp_allocator)
	used_spall_names := make(map[string]bool, context.temp_allocator)
	names := suite_names(packages, opts.target_path)

	all_ok := true
	for pkg, idx in packages {
		for b in pkg.benches {
			for w in b.warnings {
				fmt.eprintfln("obench: warning: %s", w)
			}
		}
		outputs := Package_Outputs {
			json  = json_target,
			md    = opts.md_path,
			csv   = opts.csv_path,
			spall = opts.spall_path,
		}
		if multi {
			if outputs.json != "" {
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
			all_ok = false
			continue
		}

		if !run_package(pkg, idx, names[idx], work_dir, opts, outputs) {
			all_ok = false
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
		}
		all_ok &= json_ok
		all_ok &= _write_merged(opts.md_path, md_parts[:], "Markdown", _merge_markdown)
		all_ok &= _write_merged(opts.csv_path, csv_parts[:], "CSV", _merge_csv)
	}
	// --save-baseline and --json may name two different files.
	if json_ok &&
	   opts.json_path != "" &&
	   opts.save_baseline != "" &&
	   opts.json_path != opts.save_baseline &&
	   os.exists(opts.json_path) {
		data, err := os.read_entire_file(opts.json_path, context.temp_allocator)
		if err != nil || os.write_entire_file(opts.save_baseline, data) != nil {
			fmt.eprintfln("obench: could not write baseline '%s'", opts.save_baseline)
			all_ok = false
		}
	}

	return all_ok
}

list_packages :: proc(packages: []Discovered_Package) {
	cwd, _ := os.get_working_directory(context.temp_allocator)
	for pkg in packages {
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
		passed, err := obench.compare_baseline_files(
			opts.compare_old,
			opts.compare_new,
			opts.threshold_pct,
			!opts.no_color,
			opts.fail_on_regression,
		)
		if err != nil {
			fmt.eprintfln(
				"obench compare: could not read '%s' or '%s' (%v)",
				opts.compare_old,
				opts.compare_new,
				err,
			)
			os.exit(EXIT_FAILURE)
		}
		if !passed {
			os.exit(EXIT_FAILURE)
		}
		return

	case .List, .Run:
	}

	if !os.is_directory(opts.target_path) {
		fmt.eprintfln("obench: '%s' is not a directory", opts.target_path)
		os.exit(EXIT_USAGE)
	}

	packages := discover_all_packages(opts.target_path)
	defer {
		for &pkg in packages {
			destroy_discovered_package(&pkg)
		}
		delete(packages)
	}

	if len(packages) == 0 {
		fmt.eprintfln("obench: no benchmark packages found under '%s'", opts.target_path)
		fmt.eprintln(
			"A benchmark package defines 'bench_<name> :: proc(b: ^obench.Bencher)' procedures.",
		)
		os.exit(EXIT_FAILURE)
	}

	if opts.subcommand == .List {
		list_packages(packages[:])
		return
	}

	if !run_all(packages[:], opts) {
		os.exit(EXIT_FAILURE)
	}
}
