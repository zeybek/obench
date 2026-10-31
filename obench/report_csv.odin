package obench

import "core:encoding/csv"
import "core:fmt"
import "core:io"
import "core:os"

/*
Column header of the CSV report written by `write_csv_report`.
*/
CSV_HEADER :: [?]string {
	"suite_name",
	"full_name",
	"group_name",
	"name",
	"param",
	"threads",
	"error",
	"samples",
	"batch_size",
	"min_ns",
	"p50_ns",
	"p95_ns",
	"p99_ns",
	"max_ns",
	"mean_ns",
	"std_dev_ns",
	"ci95_ns",
	"mad_ns",
	"median_cycles",
	"mb_per_sec",
	"items_per_sec",
	"allocs_per_op",
	"resizes_per_op",
	"alloc_bytes_per_op",
	"temp_allocs_per_op",
	"temp_bytes_per_op",
}

@(private = "file")
_csv_number :: proc(v: f64) -> string {
	return fmt.tprintf("%.4f", v)
}

/*
Writes an RFC 4180 CSV report (CRLF line endings, quoted where needed) to `w`.
*/
@(require_results)
write_csv_report :: proc(w: io.Writer, s: ^Suite) -> io.Error {
	cw := csv.Writer {
		use_crlf = true,
	}
	csv.writer_init(&cw, w)

	header := CSV_HEADER
	csv.write(&cw, header[:]) or_return

	for r in s.results {
		st := r.stats
		record := [?]string {
			s.name,
			r.full_name,
			r.group_name,
			r.name,
			fmt.tprintf("%d", r.param),
			fmt.tprintf("%d", r.threads),
			bench_error_string(r.error),
			fmt.tprintf("%d", st.samples),
			fmt.tprintf("%d", st.batch_size),
			_csv_number(st.min_ns),
			_csv_number(st.p50_ns),
			_csv_number(st.p95_ns),
			_csv_number(st.p99_ns),
			_csv_number(st.max_ns),
			_csv_number(st.mean_ns),
			_csv_number(st.std_dev_ns),
			_csv_number(st.ci95_ns),
			_csv_number(st.mad_ns),
			_csv_number(st.median_cycles),
			_csv_number(st.mb_per_sec),
			_csv_number(st.items_per_sec),
			_csv_number(st.allocs_per_op),
			_csv_number(st.resizes_per_op),
			_csv_number(st.alloc_bytes_per_op),
			_csv_number(st.temp_allocs_per_op),
			_csv_number(st.temp_bytes_per_op),
		}
		#assert(len(record) == len(CSV_HEADER))
		csv.write(&cw, record[:]) or_return
	}
	return nil
}

/*
Writes an RFC 4180 CSV report to `path`.
*/
@(require_results)
save_csv_report :: proc(s: ^Suite, path: string) -> Report_Error {
	return _save_rendered(path, s, proc(w: io.Writer, data: rawptr) -> Report_Error {
		return os.Error(write_csv_report(w, (^Suite)(data)))
	})
}
