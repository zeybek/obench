package main

import obench "../../obench"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:strings"

/*
Formats `obench export` writes, for services and tools that don't read obench's own JSON.
*/
Export_Format :: enum {
	BMF, // Bencher Metric Format (https://bencher.dev/docs/reference/bencher-metric-format/)
	GAB, // github-action-benchmark's `customSmallerIsBetter`
	GBench, // Google Benchmark's JSON output
	JSONL, // one JSON object per line and benchmark, with the run's metadata
}

@(private)
parse_export_format :: proc(name: string) -> (format: Export_Format, ok: bool) {
	switch name {
	case "bmf":
		return .BMF, true
	case "gab":
		return .GAB, true
	case "gbench":
		return .GBench, true
	case "jsonl":
		return .JSONL, true
	}
	return
}

// `<suite>/<benchmark>`, unique across the suites of a merged report.
@(private = "file")
_export_name :: proc(e: obench.Export_Entry) -> string {
	return fmt.tprintf("%s/%s", e.suite_name, e.full_name)
}

@(private = "file")
_BMF_Metric :: struct {
	value:       f64 `json:"value"`,
	lower_value: f64 `json:"lower_value,omitempty"`,
	upper_value: f64 `json:"upper_value,omitempty"`,
}

@(private = "file")
_GAB_Entry :: struct {
	name:  string `json:"name"`,
	unit:  string `json:"unit"`,
	value: f64 `json:"value"`,
	range: string `json:"range,omitempty"`,
	extra: string `json:"extra,omitempty"`,
}

@(private = "file")
_GBench_Context :: struct {
	executable:         string `json:"executable"`,
	library_build_type: string `json:"library_build_type"`,
	obench_version:     string `json:"obench_version"`,
	odin_version:       string `json:"odin_version"`,
	optimization:       string `json:"optimization"`,
	os:                 string `json:"os"`,
	arch:               string `json:"arch"`,
}

@(private = "file")
_GBench_Benchmark :: struct {
	name:             string `json:"name"`,
	run_name:         string `json:"run_name"`,
	run_type:         string `json:"run_type"`,
	repetitions:      int `json:"repetitions"`,
	repetition_index: int `json:"repetition_index"`,
	threads:          int `json:"threads"`,
	iterations:       int `json:"iterations"`,
	real_time:        f64 `json:"real_time"`,
	cpu_time:         f64 `json:"cpu_time"`,
	time_unit:        string `json:"time_unit"`,
	items_per_second: f64 `json:"items_per_second,omitempty"`,
	bytes_per_second: f64 `json:"bytes_per_second,omitempty"`,
}

@(private = "file")
_GBench_Report :: struct {
	ctx:        _GBench_Context `json:"context"`,
	benchmarks: []_GBench_Benchmark `json:"benchmarks"`,
}

@(private = "file")
_JSONL_Line :: struct {
	suite:              string `json:"suite"`,
	name:               string `json:"name"`,
	samples:            int `json:"samples"`,
	batch_size:         int `json:"batch_size"`,
	min_ns:             f64 `json:"min_ns"`,
	p50_ns:             f64 `json:"p50_ns"`,
	p99_ns:             f64 `json:"p99_ns"`,
	mean_ns:            f64 `json:"mean_ns"`,
	std_dev_ns:         f64 `json:"std_dev_ns"`,
	allocs_per_op:      f64 `json:"allocs_per_op"`,
	alloc_bytes_per_op: f64 `json:"alloc_bytes_per_op"`,
	temp_allocs_per_op: f64 `json:"temp_allocs_per_op"`,
	temp_bytes_per_op:  f64 `json:"temp_bytes_per_op"`,
	custom_metrics:     []obench.Custom_Metric `json:"custom_metrics,omitempty"`,
	obench_version:     string `json:"obench_version"`,
	odin_version:       string `json:"odin_version"`,
	optimization:       string `json:"optimization"`,
	os:                 string `json:"os"`,
	arch:               string `json:"arch"`,
}

// A custom metric's unit as a BMF measure name: lowercase, with anything but letters and
// digits turned into `-`.
@(private = "file")
_measure_name :: proc(unit: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for r in strings.to_lower(unit, context.temp_allocator) {
		ok := (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9')
		strings.write_rune(&sb, ok ? r : '-')
	}
	return strings.to_string(sb)
}

/*
Writes `doc` in `format` to `w`. Benchmarks that failed have no numbers and are left out.
Everything is allocated with `context.temp_allocator`.

BMF gets `latency` (p50 with the fastest sample and p99 as bounds), `allocs-per-op` and
`bytes-per-op`, the temp allocator's counts when it was used, `throughput` when the benchmark
set items, and every custom metric under its unit. github-action-benchmark's
`customSmallerIsBetter` only gets the time and the heap counts, because a custom metric may
be one where bigger is better. Google Benchmark's format has room for the time only.
*/
@(private)
write_export :: proc(
	w: io.Writer,
	doc: obench.Export_Document,
	format: Export_Format,
) -> io.Error {
	opt := json.Marshal_Options {
		pretty           = format != .JSONL,
		use_spaces       = true,
		spaces           = 2,
		sort_maps_by_key = true,
	}
	// `json.marshal` rather than `json.marshal_to_writer`, which takes its options by pointer in
	// Odin dev-2026-10 and by value from dev-2026-11a on.
	marshal :: proc(w: io.Writer, v: any, opt: ^json.Marshal_Options) -> io.Error {
		data, err := json.marshal(v, opt^, context.temp_allocator)
		if err != nil {
			return .Unknown
		}
		_, write_err := io.write(w, data)
		return write_err
	}

	switch format {
	case .BMF:
		report := make(map[string]map[string]_BMF_Metric, context.temp_allocator)
		for e in doc.benchmarks {
			if e.error != "" {
				continue
			}
			m := make(map[string]_BMF_Metric, context.temp_allocator)
			m["latency"] = {
				value       = e.p50_ns,
				lower_value = e.min_ns,
				upper_value = e.p99_ns,
			}
			m["allocs-per-op"] = {
				value = e.allocs_per_op,
			}
			m["bytes-per-op"] = {
				value = e.alloc_bytes_per_op,
			}
			if e.temp_allocs_per_op > 0 || e.temp_bytes_per_op > 0 {
				m["temp-allocs-per-op"] = {
					value = e.temp_allocs_per_op,
				}
				m["temp-bytes-per-op"] = {
					value = e.temp_bytes_per_op,
				}
			}
			if e.items_per_sec > 0 {
				m["throughput"] = {
					value = e.items_per_sec,
				}
			}
			for cm in e.custom_metrics {
				m[_measure_name(cm.unit)] = {
					value = cm.value,
				}
			}
			report[_export_name(e)] = m
		}
		marshal(w, report, &opt) or_return

	case .GAB:
		entries := make([dynamic]_GAB_Entry, context.temp_allocator)
		for e in doc.benchmarks {
			if e.error != "" {
				continue
			}
			name := _export_name(e)
			append(
				&entries,
				_GAB_Entry {
					name = name,
					unit = "ns",
					value = e.p50_ns,
					range = fmt.tprintf("± %.2f", e.ci95_ns),
					extra = fmt.tprintf(
						"fastest %.2f ns, p99 %.2f ns, %d samples",
						e.min_ns,
						e.p99_ns,
						e.samples,
					),
				},
				_GAB_Entry {
					name = fmt.tprintf("%s (allocs/op)", name),
					unit = "allocs",
					value = e.allocs_per_op,
				},
				_GAB_Entry {
					name = fmt.tprintf("%s (bytes/op)", name),
					unit = "B",
					value = e.alloc_bytes_per_op,
				},
			)
		}
		marshal(w, entries[:], &opt) or_return

	case .GBench:
		benches := make([dynamic]_GBench_Benchmark, context.temp_allocator)
		for e in doc.benchmarks {
			if e.error != "" {
				continue
			}
			name := _export_name(e)
			append(
				&benches,
				_GBench_Benchmark {
					name             = name,
					run_name         = name,
					run_type         = "iteration",
					repetitions      = 1,
					threads          = max(e.threads, 1),
					iterations       = e.samples * e.batch_size,
					real_time        = e.p50_ns,
					cpu_time         = e.p50_ns,
					time_unit        = "ns",
					items_per_second = e.items_per_sec,
					bytes_per_second = e.mb_per_sec * 1024 * 1024, // from MiB/s
				},
			)
		}
		report := _GBench_Report {
			ctx = {
				executable = "obench",
				library_build_type = "release",
				obench_version = doc.obench_version,
				odin_version = doc.odin_version,
				optimization = doc.optimization,
				os = doc.os,
				arch = doc.arch,
			},
			benchmarks = benches[:],
		}
		marshal(w, report, &opt) or_return

	case .JSONL:
		for e in doc.benchmarks {
			if e.error != "" {
				continue
			}
			line := _JSONL_Line {
				suite              = e.suite_name,
				name               = e.full_name,
				samples            = e.samples,
				batch_size         = e.batch_size,
				min_ns             = e.min_ns,
				p50_ns             = e.p50_ns,
				p99_ns             = e.p99_ns,
				mean_ns            = e.mean_ns,
				std_dev_ns         = e.std_dev_ns,
				allocs_per_op      = e.allocs_per_op,
				alloc_bytes_per_op = e.alloc_bytes_per_op,
				temp_allocs_per_op = e.temp_allocs_per_op,
				temp_bytes_per_op  = e.temp_bytes_per_op,
				custom_metrics     = e.custom_metrics,
				obench_version     = doc.obench_version,
				odin_version       = doc.odin_version,
				optimization       = doc.optimization,
				os                 = doc.os,
				arch               = doc.arch,
			}
			marshal(w, line, &opt) or_return
			io.write_byte(w, '\n') or_return
		}
		return nil
	}
	io.write_byte(w, '\n') or_return
	return nil
}
