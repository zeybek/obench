package obench

import "core:encoding/json"
import "core:io"
import "core:os"
import "core:strings"

/*
Error returned by the procedures that read or write report files.
*/
Report_Error :: union #shared_nil {
	os.Error,
	json.Marshal_Error,
	json.Unmarshal_Error,
}

/*
Short machine-readable name for a `Bench_Error`, as written to reports.
*/
@(require_results)
bench_error_string :: proc "contextless" (e: Bench_Error) -> string {
	switch e {
	case .None:
		return ""
	case .No_Measurement:
		return "no_measurement"
	case .Loop_Exited_Early:
		return "loop_exited_early"
	case .Measured_Twice:
		return "measured_twice"
	}
	return "unknown"
}

// Renders a report into memory with `write` and writes it to `path` in one go.
@(private)
_save_rendered :: proc(
	path: string,
	data: rawptr,
	write: proc(w: io.Writer, data: rawptr) -> Report_Error,
) -> Report_Error {
	sb := strings.builder_make(context.temp_allocator)
	write(strings.to_writer(&sb), data) or_return
	return os.write_entire_file(path, strings.to_string(sb))
}
