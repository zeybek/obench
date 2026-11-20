package main

import obench "../../obench"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

/*
Writes the `--html` page of a run over several packages from their merged JSON report, which
is `json_target` when the run writes one and a merge of `parts` in `work_dir` otherwise, with
the `--baseline` report drawn over it when that can be read.
*/
@(private)
write_merged_html :: proc(
	opts: CLI_Options,
	json_target: string,
	parts: []string,
	work_dir: string,
) -> bool {
	if len(parts) == 0 {
		return true
	}
	merged := json_target
	if merged == "" {
		merged, _ = filepath.join({work_dir, "merged.json"}, context.temp_allocator)
		if err := obench.merge_json_reports(parts, merged); err != nil {
			fmt.eprintfln("obench: could not merge the reports for '%s' (%v)", opts.html_path, err)
			return false
		}
	}
	doc, err := obench.read_json_report(merged, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("obench: could not read '%s' for the HTML report (%v)", merged, err)
		return false
	}
	baseline: Maybe(obench.Export_Document)
	if opts.load_baseline != "" {
		if b, base_err := obench.read_json_report(opts.load_baseline, context.temp_allocator);
		   base_err == nil {
			baseline = b
		}
	}
	sb := strings.builder_make(context.temp_allocator)
	obench.write_html_report(strings.to_writer(&sb), doc, baseline)
	if write_err := os.write_entire_file(opts.html_path, strings.to_string(sb)); write_err != nil {
		fmt.eprintfln(
			"obench: could not write HTML report to '%s' (%v)",
			opts.html_path,
			write_err,
		)
		return false
	}
	return true
}
