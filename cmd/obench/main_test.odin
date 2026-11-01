package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// These tests run from the repository root (`odin test cmd/obench`), so the example
// packages are reachable at `examples/...`.

@(test)
test_parse_cli_args_run_options :: proc(t: ^testing.T) {
	opts, err := parse_cli_args(
		{
			"run",
			"examples",
			"-n",
			"5",
			"--warmup=3",
			"-o",
			"aggressive",
			"--collection",
			"lib=./lib",
			"--zero-alloc",
			"--json",
			"out.json",
		},
	)
	defer destroy_cli_options(&opts)
	testing.expect_value(t, err, "")
	testing.expect_value(t, opts.subcommand, Subcommand.Run)
	testing.expect_value(t, opts.target_path, "examples")
	testing.expect_value(t, opts.samples, 5)
	testing.expect_value(t, opts.warmup_ms, 3)
	testing.expect_value(t, opts.opt_mode, "aggressive")
	testing.expect_value(t, len(opts.collections), 1)
	testing.expect_value(t, opts.zero_alloc, true)
	testing.expect_value(t, opts.json_path, "out.json")
}

@(test)
test_parse_cli_args_rejects_bad_input :: proc(t: ^testing.T) {
	bad_inputs := [][]string {
		{"--bogus"},
		{"--samples"},
		{"-n", "zero"},
		{"-n", "0"},
		{"--warmup", "-1"},
		{"-o", "fast"},
		{"--threshold", "abc"},
		{"--collection", "missing_equals"},
		{"compare", "only_one.json"},
		{"run", "a", "b"},
		{"-n", "5", "--samples", "100"},
		{"-f", "a", "--filter", "b"},
		{"-w", "1", "--warmup", "2"},
		{"-o", "none", "--opt", "speed"},
	}
	for args in bad_inputs {
		opts, err := parse_cli_args(args)
		destroy_cli_options(&opts)
		testing.expectf(t, err != "", "expected an error for %v", args)
	}
}

@(test)
test_parse_cli_args_subcommands :: proc(t: ^testing.T) {
	{
		opts, err := parse_cli_args({"compare", "old.json", "new.json", "--fail-on-regression"})
		defer destroy_cli_options(&opts)
		testing.expect_value(t, err, "")
		testing.expect_value(t, opts.subcommand, Subcommand.Compare)
		testing.expect_value(t, opts.compare_old, "old.json")
		testing.expect_value(t, opts.compare_new, "new.json")
		testing.expect_value(t, opts.fail_on_regression, true)
	}
	{
		opts, err := parse_cli_args({"examples", "--list"})
		defer destroy_cli_options(&opts)
		testing.expect_value(t, err, "")
		testing.expect_value(t, opts.subcommand, Subcommand.List)
		testing.expect_value(t, opts.target_path, "examples")
	}
	{
		opts, err := parse_cli_args(nil)
		defer destroy_cli_options(&opts)
		testing.expect_value(t, err, "")
		testing.expect_value(t, opts.subcommand, Subcommand.Run)
		testing.expect_value(t, opts.target_path, ".")
	}
}

@(test)
test_discover_example_package :: proc(t: ^testing.T) {
	pkg, status := discover_package("examples/sorting")
	defer destroy_discovered_package(&pkg)
	testing.expect_value(t, status, Discover_Status.Benchmark_Package)
	testing.expect_value(t, pkg.pkg_name, "sorting_bench")
	testing.expect_value(t, pkg.has_main, false)
	testing.expect_value(t, pkg.lib_import, "../../obench")
	testing.expect_value(t, len(pkg.benches), 2)
	if len(pkg.benches) == 2 {
		b := pkg.benches[0]
		testing.expect_value(t, b.group_name, "in_place_sort")
		testing.expect_value(t, b.bench_name, "insertion_sort")
		testing.expect_value(t, b.zero_alloc, true)
		testing.expect_value(t, len(b.params), 3)
	}
	testing.expect_value(t, len(check_package(pkg)), 0)
}

@(test)
test_discover_skips_non_benchmark_packages :: proc(t: ^testing.T) {
	// The library itself is recognized (and has bench_* procedures that don't take ^Bencher).
	lib, lib_status := discover_package("obench")
	defer destroy_discovered_package(&lib)
	testing.expect_value(t, lib_status, Discover_Status.Obench_Library)

	// A program with main() but no benchmarks must never be run.
	cli, cli_status := discover_package("cmd/obench")
	defer destroy_discovered_package(&cli)
	testing.expect_value(t, cli_status, Discover_Status.Not_Benchmark)

	packages, _ := discover_all_packages(".")
	defer {
		for &p in packages {
			destroy_discovered_package(&p)
		}
		delete(packages)
	}
	testing.expect_value(t, len(packages), 5)
}

@(private = "file")
_write_temp_package :: proc(t: ^testing.T, file_name, source: string) -> (dir: string, ok: bool) {
	tmp, err := os.make_directory_temp("", "obench-test-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {
		return "", false
	}
	path, _ := filepath.join({tmp, file_name}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(path, source), nil) {
		return "", false
	}
	return tmp, true
}

@(test)
test_discover_signature_privacy_and_imports :: proc(t: ^testing.T) {
	source := `package demo_bench

import ob "shared:bench/obench"

// @params(1, 2, 3)
bench_ok :: proc(b: ^ob.Bencher) {}

@(private)
bench_hidden :: proc(b: ^ob.Bencher) {}

bench_helper :: proc() -> int { return 1 }

bench_two_args :: proc(a, b: int) {}
`
	dir, ok := _write_temp_package(t, "demo_bench.odin", source)
	if !ok {
		return
	}
	defer os.remove_all(dir)

	pkg, status := discover_package(dir)
	defer destroy_discovered_package(&pkg)
	testing.expect_value(t, status, Discover_Status.Benchmark_Package)
	testing.expect_value(t, len(pkg.benches), 2)
	testing.expect_value(t, pkg.lib_import, "shared:bench/obench")

	lib := resolve_lib_import(pkg)
	testing.expect_value(t, lib.import_path, "shared:bench/obench")
	testing.expect_value(t, lib.collection, "")

	problems := check_package(pkg)
	testing.expect_value(t, len(problems), 1)
	if len(problems) == 1 {
		testing.expect(
			t,
			strings.contains(problems[0], "bench_hidden"),
			"the private benchmark must be named",
		)
	}
}

@(test)
test_annotations_are_parsed_strictly :: proc(t: ^testing.T) {
	source := `package strict_bench

import obench "../obench"

// Don't add @zero_alloc here, the loop allocates on purpose.
bench_prose :: proc(b: ^obench.Bencher) {}

// @params(8, 1<<10)
bench_bad_params :: proc(b: ^obench.Bencher) {}

// @threads(2, 0)
bench_bad_threads :: proc(b: ^obench.Bencher) {}

// @zero_alloc @params(1, 2, 3)
// @thread(4)
bench_typo :: proc(b: ^obench.Bencher) {}
`
	dir, ok := _write_temp_package(t, "strict_bench.odin", source)
	if !ok {
		return
	}
	defer os.remove_all(dir)

	pkg, status := discover_package(dir)
	defer destroy_discovered_package(&pkg)
	if !testing.expect_value(t, status, Discover_Status.Benchmark_Package) ||
	   !testing.expect_value(t, len(pkg.benches), 4) {
		return
	}
	prose, bad_params, bad_threads, typo :=
		pkg.benches[0], pkg.benches[1], pkg.benches[2], pkg.benches[3]
	testing.expect(t, !prose.zero_alloc, "@zero_alloc in the middle of a sentence is prose")
	testing.expect_value(t, len(prose.problems), 0)
	testing.expect_value(t, len(bad_params.problems), 1)
	testing.expect_value(t, len(bad_threads.problems), 1)
	testing.expect(t, typo.zero_alloc)
	testing.expect_value(t, len(typo.params), 3)
	testing.expect_value(t, len(typo.problems), 0)
	testing.expect_value(t, len(typo.warnings), 1)

	problems := check_package(pkg)
	testing.expect_value(t, len(problems), 2)
	for p in problems {
		testing.expectf(t, strings.contains(p, "strict_bench.odin("), "%q names no file", p)
	}
}

@(test)
test_duplicate_package_names_get_distinct_suites :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "obench-test-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {
		return
	}
	defer os.remove_all(root)
	src := "package dup_bench\n\nimport obench \"../obench\"\n\nbench_x :: proc(b: ^obench.Bencher) {}\n"
	_write_test_file(t, root, "a", "dup_bench.odin", src)
	_write_test_file(t, root, "b/c", "dup_bench.odin", src)
	_write_test_file(
		t,
		root,
		"solo",
		"solo_bench.odin",
		"package solo_bench\n\nimport obench \"../obench\"\n\nbench_y :: proc(b: ^obench.Bencher) {}\n",
	)

	packages, _ := discover_all_packages(root)
	defer {
		for &p in packages {
			destroy_discovered_package(&p)
		}
		delete(packages)
	}
	if !testing.expect_value(t, len(packages), 3) {
		return
	}
	names := suite_names(packages[:], root)
	testing.expect_value(t, names[0], "dup_bench (a)")
	testing.expect_value(t, names[1], "dup_bench (b/c)")
	testing.expect_value(t, names[2], "solo_bench")
}

@(test)
test_discover_reports_parse_errors :: proc(t: ^testing.T) {
	dir, ok := _write_temp_package(
		t,
		"broken_bench.odin",
		"package broken_bench\n\nbench_x :: proc(b: ^obench.Bencher {\n",
	)
	if !ok {
		return
	}
	defer os.remove_all(dir)

	pkg, status := discover_package(dir)
	defer destroy_discovered_package(&pkg)
	testing.expect_value(t, status, Discover_Status.Parse_Error)
}

@(test)
test_unparsed_packages_are_counted :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "obench-test-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {
		return
	}
	defer os.remove_all(root)
	_write_test_file(
		t,
		root,
		"good",
		"good_bench.odin",
		"package good_bench\n\nimport obench \"../obench\"\n\nbench_x :: proc(b: ^obench.Bencher) {}\n",
	)
	_write_test_file(
		t,
		root,
		"bad",
		"bad_bench.odin",
		"package bad_bench\n\nbench_y :: proc(b: ^obench.Bencher {\n",
	)

	packages, unparsed := discover_all_packages(root)
	defer {
		for &p in packages {
			destroy_discovered_package(&p)
		}
		delete(packages)
	}
	testing.expect_value(t, len(packages), 1)
	testing.expect_value(t, unparsed, 1)
}

// An OS other than the one the tests run on.
@(private = "file")
_other_os :: proc() -> string {
	return "linux" if ODIN_OS == .Darwin else "darwin"
}

@(test)
test_file_name_suffixes_follow_the_compiler :: proc(t: ^testing.T) {
	this_os := strings.to_lower(ODIN_OS_STRING, context.temp_allocator)
	this_arch := ODIN_ARCH_STRING
	other_arch := "amd64" if ODIN_ARCH == .arm64 else "arm64"
	Case :: struct {
		name:     string,
		excluded: bool,
	}
	cases := []Case {
		{"plain.odin", false},
		{"my_bench.odin", false},
		{".hidden.odin", true},
		{fmt.tprintf("x_%s.odin", _other_os()), true},
		{fmt.tprintf("x_%s.odin", this_os), false},
		{fmt.tprintf("x_%s.odin", other_arch), true},
		{fmt.tprintf("x_%s.odin", this_arch), false},
		{fmt.tprintf("x_%s_%s.odin", this_os, this_arch), false},
		{fmt.tprintf("x_%s_%s.odin", this_os, other_arch), true},
		{fmt.tprintf("x_%s_%s.odin", _other_os(), this_arch), true},
		{fmt.tprintf("%s_%s.odin", this_os, this_arch), false},
	}
	for c in cases {
		testing.expectf(
			t,
			excluded_by_file_name(c.name) == c.excluded,
			"%s: expected excluded=%v",
			c.name,
			c.excluded,
		)
	}
}

@(test)
test_discover_honors_build_constraints :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "obench-test-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {
		return
	}
	defer os.remove_all(root)
	header := "package tags_bench\n\nimport obench \"../obench\"\n\n"
	_write_test_file(
		t,
		root,
		"pkg",
		"a_bench.odin",
		fmt.tprintf("%sbench_here :: proc(b: ^obench.Bencher) {{}}\n", header),
	)
	_write_test_file(
		t,
		root,
		"pkg",
		fmt.tprintf("b_%s.odin", _other_os()),
		fmt.tprintf("%sbench_other_os :: proc(b: ^obench.Bencher) {{}}\n", header),
	)
	_write_test_file(
		t,
		root,
		"pkg",
		"c_tagged.odin",
		fmt.tprintf(
			"#+build %s\n%sbench_tagged :: proc(b: ^obench.Bencher) {{}}\n",
			_other_os(),
			header,
		),
	)
	_write_test_file(
		t,
		root,
		"pkg",
		"d_ignored.odin",
		"#+build ignore\npackage tags_bench\n\nmain :: proc() {}\n",
	)

	dir, _ := filepath.join({root, "pkg"}, context.temp_allocator)
	pkg, status := discover_package(dir)
	defer destroy_discovered_package(&pkg)
	if !testing.expect_value(t, status, Discover_Status.Benchmark_Package) {
		return
	}
	testing.expect_value(t, pkg.has_main, false)
	testing.expect_value(t, len(pkg.benches), 1)
	if len(pkg.benches) == 1 {
		testing.expect_value(t, pkg.benches[0].proc_name, "bench_here")
	}
}

@(test)
test_discover_handles_brackets_in_paths :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "obench-test-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {
		return
	}
	defer os.remove_all(root)
	_write_test_file(
		t,
		root,
		"br [x]",
		"br_bench.odin",
		"package br_bench\n\nimport obench \"../obench\"\n\nbench_x :: proc(b: ^obench.Bencher) {}\n",
	)
	dir, _ := filepath.join({root, "br [x]"}, context.temp_allocator)
	pkg, status := discover_package(dir)
	defer destroy_discovered_package(&pkg)
	testing.expect_value(t, status, Discover_Status.Benchmark_Package)
	testing.expect_value(t, len(pkg.benches), 1)
}

@(test)
test_detached_annotations_are_reported :: proc(t: ^testing.T) {
	source := `package gap_bench

import obench "../obench"

// @zero_alloc

bench_gap :: proc(b: ^obench.Bencher) {}

// @zero_alloc
bench_attached :: proc(b: ^obench.Bencher) {}

// Mentions @zero_alloc in prose, so it is not an annotation.
`
	dir, ok := _write_temp_package(t, "gap_bench.odin", source)
	if !ok {
		return
	}
	defer os.remove_all(dir)

	pkg, status := discover_package(dir)
	defer destroy_discovered_package(&pkg)
	if !testing.expect_value(t, status, Discover_Status.Benchmark_Package) ||
	   !testing.expect_value(t, len(pkg.benches), 2) {
		return
	}
	testing.expect(t, !pkg.benches[0].zero_alloc)
	testing.expect(t, pkg.benches[1].zero_alloc)
	testing.expect_value(t, len(pkg.warnings), 1)
	if len(pkg.warnings) == 1 {
		testing.expect(t, strings.contains(pkg.warnings[0], "gap_bench.odin(5)"))
	}
}

@(test)
test_generate_runner_source :: proc(t: ^testing.T) {
	pkg, status := discover_package("examples/sorting")
	defer destroy_discovered_package(&pkg)
	if !testing.expect_value(t, status, Discover_Status.Benchmark_Package) {
		return
	}

	lib := resolve_lib_import(pkg)
	testing.expect_value(t, lib.import_path, LIB_COLLECTION + ":.")
	lib_dir, lib_err := os.get_absolute_path("obench", context.temp_allocator)
	testing.expect_value(t, lib_err, nil)
	testing.expect_value(
		t,
		lib.collection,
		fmt.tprintf("-collection:%s=%s", LIB_COLLECTION, lib_dir),
	)

	warnings := make([dynamic]string, context.temp_allocator)
	source := generate_runner_source(pkg, lib.import_path, pkg.pkg_name, &warnings)
	testing.expect_value(t, len(warnings), 0)
	testing.expect(t, strings.contains(source, "package obench_runner"))
	testing.expect(t, strings.contains(source, `obench.suite_create("sorting_bench")`))
	testing.expect(t, strings.contains(source, "obench.group_params(g0, []int{32, 128, 512})"))
	testing.expect(
		t,
		strings.contains(source, "target.bench_in_place_sort__slice_sort, zero_alloc = true"),
	)

	// Conflicting @params inside one group produce a warning.
	append(&pkg.benches[1].params, 1024)
	clear(&warnings)
	renamed := generate_runner_source(pkg, lib.import_path, "renamed (dir)", &warnings)
	testing.expect_value(t, len(warnings), 1)
	testing.expect(t, strings.contains(renamed, `obench.suite_create("renamed (dir)")`))
}

@(private = "file")
_write_test_file :: proc(t: ^testing.T, root, rel_dir, file_name, source: string) {
	dir, _ := filepath.join({root, rel_dir}, context.temp_allocator)
	if mk_err := os.make_directory_all(dir); mk_err != os.General_Error.Exist {
		testing.expect_value(t, mk_err, nil)
	}
	path, _ := filepath.join({dir, file_name}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(path, source), nil)
}

@(private = "file")
_discovered_names :: proc(root: string) -> []string {
	packages, _ := discover_all_packages(root)
	defer {
		for &p in packages {
			destroy_discovered_package(&p)
		}
		delete(packages)
	}
	names := make([]string, len(packages), context.temp_allocator)
	for p, i in packages {
		names[i] = strings.clone(p.pkg_name, context.temp_allocator)
	}
	return names
}

@(test)
test_discover_skips_vendored_library :: proc(t: ^testing.T) {
	// A project with its own benchmarks and a copy of the library package, with a stray
	// benchmark package below it.
	root, err := os.make_directory_temp("", "obench-test-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {
		return
	}
	defer os.remove_all(root)

	_write_test_file(t, root, "obench", "obench.odin", "package obench\n\nBencher :: struct {}\n")
	_write_test_file(
		t,
		root,
		"obench/examples/demo",
		"demo_bench.odin",
		"package demo_bench\n\nimport obench \"../..\"\n\nbench_x :: proc(b: ^obench.Bencher) {}\n",
	)
	_write_test_file(
		t,
		root,
		"bench",
		"mine_bench.odin",
		"package mine_bench\n\nimport obench \"../obench\"\n\nbench_y :: proc(b: ^obench.Bencher) {}\n",
	)

	names := _discovered_names(root)
	testing.expect_value(t, len(names), 1)
	if len(names) == 1 {
		testing.expect_value(t, names[0], "mine_bench")
	}
}

@(test)
test_discover_skips_vendored_checkout :: proc(t: ^testing.T) {
	// A project with its own benchmarks and a copy of the whole obench repository in libs/obench,
	// as `git subtree add` leaves it.
	root, err := os.make_directory_temp("", "obench-test-*", context.temp_allocator)
	if !testing.expect_value(t, err, nil) {
		return
	}
	defer os.remove_all(root)

	_write_test_file(
		t,
		root,
		"libs/obench/obench",
		"obench.odin",
		"package obench\n\nBencher :: struct {}\n",
	)
	_write_test_file(
		t,
		root,
		"libs/obench/cmd/obench",
		"main.odin",
		"package main\n\nmain :: proc() {}\n",
	)
	_write_test_file(
		t,
		root,
		"libs/obench/examples/demo",
		"demo_bench.odin",
		"package demo_bench\n\nimport obench \"../../obench\"\n\nbench_x :: proc(b: ^obench.Bencher) {}\n",
	)
	_write_test_file(
		t,
		root,
		"bench",
		"mine_bench.odin",
		"package mine_bench\n\nimport obench \"../libs/obench/obench\"\n\nbench_y :: proc(b: ^obench.Bencher) {}\n",
	)

	names := _discovered_names(root)
	testing.expect_value(t, len(names), 1)
	if len(names) == 1 {
		testing.expect_value(t, names[0], "mine_bench")
	}

	// Pointing the CLI at the copy itself still finds its examples.
	checkout, _ := filepath.join({root, "libs", "obench"}, context.temp_allocator)
	names = _discovered_names(checkout)
	testing.expect_value(t, len(names), 1)
	if len(names) == 1 {
		testing.expect_value(t, names[0], "demo_bench")
	}
}
