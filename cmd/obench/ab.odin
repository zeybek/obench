package main

import obench "../../obench"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:path/filepath"

// Rounds of `obench ab` when `--rounds` doesn't say: each side runs this many times.
DEFAULT_AB_ROUNDS :: 6

/*
`obench ab <baseline dir> <candidate dir>`: builds the packages of both directories, pairs
them by suite name, and runs every pair `--rounds` times, each round in a random order of the
two sides, so a machine whose speed drifts affects both alike. Each run is its own process
(see `measure_process`). The runs of each side are combined (`obench.combine_runs`) and the
candidate is compared with the baseline like `obench compare` does, process medians against
process medians. Returns the exit status.
*/
run_ab :: proc(opts: CLI_Options) -> int {
	for dir in ([]string{opts.ab_baseline, opts.ab_candidate}) {
		if !os.is_directory(dir) {
			fmt.eprintfln("obench ab: '%s' is not a directory", dir)
			return EXIT_USAGE
		}
	}
	work_dir, tmp_err := os.make_directory_temp("", "obench-*", context.temp_allocator)
	if tmp_err != nil {
		fmt.eprintfln("obench: could not create a temporary directory: %v", tmp_err)
		return EXIT_FAILURE
	}
	defer os.remove_all(work_dir)

	Side :: struct {
		dir:      string,
		work:     string,
		packages: [dynamic]Discovered_Package,
		names:    []string,
		entries:  [dynamic]obench.Export_Entry,
		first:    obench.Export_Document,
	}
	sides: [2]Side
	code := 0
	for &side, i in sides {
		side.dir = opts.ab_baseline if i == 0 else opts.ab_candidate
		side.work, _ = filepath.join(
			{work_dir, "baseline" if i == 0 else "candidate"},
			context.temp_allocator,
		)
		if err := os.make_directory(side.work); err != nil {
			fmt.eprintfln("obench: could not create '%s': %v", side.work, err)
			return EXIT_FAILURE
		}
		unparsed: int
		side.packages, unparsed = discover_all_packages(side.dir)
		if unparsed > 0 {
			code = EXIT_FAILURE
		}
		side.names = suite_names(side.packages[:], side.dir)
		side.entries = make([dynamic]obench.Export_Entry, context.temp_allocator)
	}
	defer for &side in sides {
		for &pkg in side.packages {
			destroy_discovered_package(&pkg)
		}
		delete(side.packages)
	}

	child := measuring_options(opts)
	child.quiet = true
	pairs := 0
	for &pkg_a, ia in sides[0].packages {
		name := sides[0].names[ia]
		ib := -1
		for other, j in sides[1].names {
			if other == name {
				ib = j
			}
		}
		if ib < 0 {
			fmt.eprintfln(
				"obench ab: %s has no counterpart in '%s'; skipped",
				name,
				opts.ab_candidate,
			)
			continue
		}
		pkgs := [2]^Discovered_Package{&pkg_a, &sides[1].packages[ib]}
		exes: [2]string
		built := true
		for s in 0 ..< 2 {
			if problems := check_package(pkgs[s]^); len(problems) > 0 {
				for p in problems {
					fmt.eprintfln("obench: %s", p)
				}
				built = false
				continue
			}
			ok: bool
			exes[s], ok = build_package(pkgs[s]^, s == 0 ? ia : ib, name, sides[s].work, opts)
			built &&= ok
		}
		if !built {
			code = worse_exit_code(code, EXIT_FAILURE)
			continue
		}
		pairs += 1

		docs: [2][dynamic]obench.Export_Document
		for &d in docs {
			d = make([dynamic]obench.Export_Document, context.temp_allocator)
		}
		for round in 0 ..< opts.rounds {
			order := [2]int{0, 1} if rand.int_max(2) == 0 else [2]int{1, 0}
			for s in order {
				if !opts.quiet {
					fmt.printf(
						"obench ab: %s, round %d of %d, %s: ",
						name,
						round + 1,
						opts.rounds,
						"baseline" if s == 0 else "candidate",
					)
				}
				part, _ := filepath.join(
					{sides[s].work, fmt.tprintf("package_%d_round_%d.json", ia, round)},
					context.temp_allocator,
				)
				doc, run_code, ok := measure_process(exes[s], child, part)
				code = worse_exit_code(code, run_code)
				if ok {
					append(&docs[s], doc)
				}
			}
		}
		for s in 0 ..< 2 {
			if len(docs[s]) == 0 {
				code = worse_exit_code(code, EXIT_FAILURE)
				continue
			}
			combined := obench.combine_runs(docs[s][:], context.temp_allocator)
			if len(sides[s].entries) == 0 {
				sides[s].first = combined
			}
			append(&sides[s].entries, ..combined.benchmarks)
		}
	}
	if pairs == 0 {
		fmt.eprintln("obench ab: no package of the baseline has a counterpart in the candidate")
		return worse_exit_code(code, EXIT_FAILURE)
	}

	// All packages of a side in one report, as a multi-package run merges them.
	reports: [2]obench.Export_Document
	for s in 0 ..< 2 {
		reports[s] = sides[s].first
		reports[s].benchmarks = sides[s].entries[:]
	}
	return worse_exit_code(
		code,
		compare_and_report(reports[0], reports[1], opts.ab_baseline, opts.ab_candidate, opts),
	)
}
