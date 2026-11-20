package main

import obench "../../obench"
import "core:fmt"
import "core:os"
import "core:strings"

/*
`obench compare`: reads the reports of each side, combining several into one with
`obench.combine_runs`, then prints the comparison and writes it to `--md` and `--json`.
Returns the exit status (see `obench.comparison_exit_code`).
*/
@(private)
run_compare :: proc(old_paths, new_paths: []string, opts: CLI_Options) -> int {
	baseline, base_ok := _read_side(old_paths)
	candidate, cand_ok := _read_side(new_paths)
	if !base_ok || !cand_ok {
		return EXIT_FAILURE
	}
	return compare_and_report(
		baseline,
		candidate,
		strings.join(old_paths, " ", context.temp_allocator),
		strings.join(new_paths, " ", context.temp_allocator),
		opts,
	)
}

// The reports of one side of a comparison, combined when there are several.
@(private = "file")
_read_side :: proc(paths: []string) -> (doc: obench.Export_Document, ok: bool) {
	docs := make([]obench.Export_Document, len(paths), context.temp_allocator)
	for path, i in paths {
		read, err := obench.read_json_report(path, context.temp_allocator)
		if err != nil {
			fmt.eprintfln("obench compare: could not read '%s' (%v)", path, err)
			return {}, false
		}
		docs[i] = read
	}
	return obench.combine_runs(docs, context.temp_allocator), true
}

/*
Prints the comparison of `candidate` against `baseline` under a header naming them, writes it
to `--md` and `--json`, and returns the exit status the gates ask for.
*/
@(private)
compare_and_report :: proc(
	baseline, candidate: obench.Export_Document,
	baseline_name, candidate_name: string,
	opts: CLI_Options,
) -> int {
	color := !opts.no_color && obench.stdout_wants_color()
	bold, dim, reset := "", "", ""
	if color {
		bold, dim, reset = "\x1b[1m", "\x1b[2m", "\x1b[0m"
	}
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&sb,
		"\n%sobench compare:%s %s%s vs %s (threshold=%.1f%%)%s\n",
		bold,
		reset,
		dim,
		baseline_name,
		candidate_name,
		opts.threshold_pct,
		reset,
	)
	summary := obench.write_comparison(
		strings.to_writer(&sb),
		baseline,
		candidate,
		opts.threshold_pct,
		color,
	)
	strings.write_string(&sb, "\n")
	_, _ = os.write_string(os.stdout, strings.to_string(sb))

	code := 0
	if opts.md_path != "" {
		md := strings.builder_make(context.temp_allocator)
		_ = obench.write_comparison_markdown(
			strings.to_writer(&md),
			baseline,
			candidate,
			opts.threshold_pct,
		)
		if err := os.write_entire_file(opts.md_path, strings.to_string(md)); err != nil {
			fmt.eprintfln("obench compare: could not write '%s': %v", opts.md_path, err)
			code = EXIT_FAILURE
		}
	}
	if opts.json_path != "" {
		js := strings.builder_make(context.temp_allocator)
		_, json_err := obench.write_comparison_json(
			strings.to_writer(&js),
			baseline,
			candidate,
			opts.threshold_pct,
		)
		if json_err != nil {
			fmt.eprintfln("obench compare: could not encode the comparison as JSON")
			code = EXIT_FAILURE
		} else if err := os.write_entire_file(opts.json_path, strings.to_string(js)); err != nil {
			fmt.eprintfln("obench compare: could not write '%s': %v", opts.json_path, err)
			code = EXIT_FAILURE
		}
	}
	return worse_exit_code(
		code,
		obench.comparison_exit_code(
			summary,
			opts.fail_on_regression,
			opts.fail_on_alloc_regression,
		),
	)
}
