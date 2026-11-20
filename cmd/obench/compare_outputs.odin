package main

import obench "../../obench"
import "core:fmt"
import "core:os"
import "core:strings"

/*
Writes the comparison of `obench compare` as Markdown to `--md` and as JSON to `--json`, next
to the table it prints. Returns false and says why when a report can't be read or a file
can't be written.
*/
@(private)
write_compare_outputs :: proc(opts: CLI_Options) -> bool {
	baseline, base_err := obench.read_json_report(opts.compare_old, context.temp_allocator)
	candidate, cand_err := obench.read_json_report(opts.compare_new, context.temp_allocator)
	if base_err != nil || cand_err != nil {
		fmt.eprintfln(
			"obench compare: could not read '%s' or '%s'",
			opts.compare_old,
			opts.compare_new,
		)
		return false
	}
	ok := true
	if opts.md_path != "" {
		sb := strings.builder_make(context.temp_allocator)
		_ = obench.write_comparison_markdown(
			strings.to_writer(&sb),
			baseline,
			candidate,
			opts.threshold_pct,
		)
		if err := os.write_entire_file(opts.md_path, strings.to_string(sb)); err != nil {
			fmt.eprintfln("obench compare: could not write '%s': %v", opts.md_path, err)
			ok = false
		}
	}
	if opts.json_path != "" {
		sb := strings.builder_make(context.temp_allocator)
		_, json_err := obench.write_comparison_json(
			strings.to_writer(&sb),
			baseline,
			candidate,
			opts.threshold_pct,
		)
		if json_err != nil {
			fmt.eprintfln("obench compare: could not encode the comparison as JSON")
			ok = false
		} else if err := os.write_entire_file(opts.json_path, strings.to_string(sb)); err != nil {
			fmt.eprintfln("obench compare: could not write '%s': %v", opts.json_path, err)
			ok = false
		}
	}
	return ok
}
