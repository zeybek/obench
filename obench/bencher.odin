package obench

// Signature for standard benchmarks.
Bench_Proc :: #type proc(b: ^Bencher)

/*
Ways a benchmark procedure can misuse the `Bencher` protocol. A benchmark with an error is
reported, excluded from comparisons, and makes `suite_run` return `false`.
*/
Bench_Error :: enum u8 {
	None,
	// The procedure returned without calling `step`, `iter_batched`, or `run_parallel`.
	No_Measurement,
	// The `for obench.step(b)` loop was left (`break`/`return`) before the batch finished.
	Loop_Exited_Early,
	// More than one measurement (`step` loop, `iter_batched`, `iter_with_large_drop`, or
	// `run_parallel`) in one benchmark procedure.
	Measured_Twice,
}

/*
Longest `report_metric` unit kept, in bytes. Longer units are cut at a UTF-8 boundary.
*/
MAX_METRIC_UNIT_LEN :: 32

/*
State passed into user benchmark procedures (`proc(b: ^obench.Bencher)`).
*/
Bencher :: struct {
	name:                 string,
	group_name:           string,
	param:                int,
	has_param:            bool,
	threads:              int,
	has_threads:          bool,
	user_ptr:             rawptr,

	// Hot-loop iteration state
	remaining_iters:      int,
	batch_size:           int,
	_started_sample:      bool,
	_finished:            bool,
	_paused:              bool,
	_measured_twice:      bool,
	_sample_start:        Timestamp,
	_accum_ns:            i64,
	_accum_cycles:        u64,
	_windows:             int, // Number of timed windows; each costs one clock overhead.

	// Per-operation throughput hints
	bytes_per_op:         u64,
	items_per_op:         u64,

	// Custom domain metrics. Units point into `_unit_buf`, so the caller's string may be freed
	// right after `report_metric`.
	custom_metrics:       [MAX_CUSTOM_METRICS]Custom_Metric,
	custom_metrics_count: int,
	_unit_buf:            [MAX_CUSTOM_METRICS][MAX_METRIC_UNIT_LEN]u8,

	// Zero-allocation assertion
	expect_zero_alloc:    bool,

	// Internal allocators during active sample
	_heap_counter:        ^Counting_Allocator,
	_temp_counter:        ^Counting_Allocator,
}

@(private)
_set_counters_paused :: #force_inline proc "contextless" (b: ^Bencher, paused: bool) {
	counting_allocator_set_paused(b._heap_counter, paused)
	counting_allocator_set_paused(b._temp_counter, paused)
}

/*
Drives the calibrated hot loop inside a benchmark procedure:

	bench_foo :: proc(b: ^obench.Bencher) {
		// Setup before the loop is not timed or counted
		for obench.step(b) {
			obench.black_box(do_work())
		}
		// Cleanup after the loop is not timed or counted
	}

Do not leave the loop with `break` or `return`; obench reports that as `.Loop_Exited_Early`.
*/
@(require_results)
step :: #force_inline proc(b: ^Bencher) -> bool {
	if !b._started_sample {
		b._started_sample = true
		b._windows += 1
		_set_counters_paused(b, false)
		b._sample_start = clock_now()
		return b.remaining_iters > 0
	}
	if b._finished {
		return false
	}

	b.remaining_iters -= 1
	if b.remaining_iters > 0 {
		return true
	}

	// Batch finished: stop the clock first, then the allocation counters.
	if !b._paused {
		end_ts := clock_now()
		ns, cyc := clock_elapsed(b._sample_start, end_ts)
		b._accum_ns += ns
		b._accum_cycles += cyc
		b._paused = true
	}
	_set_counters_paused(b, true)
	b._finished = true
	return false
}

/*
Pauses timer and allocation tracking inside `for obench.step(b)`.
Each `pause`/`resume` pair adds one timer overhead, which obench subtracts automatically.
*/
pause :: proc(b: ^Bencher) {
	if b._started_sample && !b._paused && !b._finished {
		end_ts := clock_now()
		ns, cyc := clock_elapsed(b._sample_start, end_ts)
		b._accum_ns += ns
		b._accum_cycles += cyc
		b._paused = true
		_set_counters_paused(b, true)
	}
}

/*
Resumes timer and allocation tracking after `obench.pause(b)`.
*/
resume :: proc(b: ^Bencher) {
	if b._started_sample && b._paused && !b._finished {
		b._paused = false
		b._windows += 1
		_set_counters_paused(b, false)
		b._sample_start = clock_now()
	}
}

/*
Pauses timing and allocation tracking for the rest of the current scope and resumes them
when the scope exits:

	for obench.step(b) {
		{
			obench.scoped_pause(b)
			reset_input(&data) // not measured
		}
		process(&data)
	}
*/
@(deferred_in = resume)
scoped_pause :: proc(b: ^Bencher) -> bool {
	pause(b)
	return true
}

/*
Sets the number of bytes processed by a single operation for throughput reporting (MiB/s, GiB/s).
*/
set_bytes :: proc "contextless" (b: ^Bencher, bytes_per_op: u64) {
	b.bytes_per_op = bytes_per_op
}

/*
Sets the number of items processed by a single operation for throughput reporting.
*/
set_items :: proc "contextless" (b: ^Bencher, items_per_op: u64) {
	b.items_per_op = items_per_op
}

/*
Records a custom metric (such as `"hit%"`, `"branches/op"`, or `"simd_lanes"`) that is
displayed and exported next to the standard statistics. The value from the last sample is
kept. Up to `MAX_CUSTOM_METRICS` distinct units are stored. `unit` is copied right away (up to
`MAX_METRIC_UNIT_LEN` bytes), so it may be a temporary string.
*/
report_metric :: proc "contextless" (b: ^Bencher, value: f64, unit: string) {
	n := min(len(unit), MAX_METRIC_UNIT_LEN)
	for n > 0 && n < len(unit) && unit[n] & 0xC0 == 0x80 {
		n -= 1 // Don't cut a UTF-8 sequence in half.
	}
	key := unit[:n]
	for i in 0 ..< b.custom_metrics_count {
		if b.custom_metrics[i].unit == key {
			b.custom_metrics[i].value = value
			return
		}
	}
	if b.custom_metrics_count < MAX_CUSTOM_METRICS {
		i := b.custom_metrics_count
		copy(b._unit_buf[i][:], key)
		b.custom_metrics[i] = Custom_Metric {
			unit  = string(b._unit_buf[i][:n]),
			value = value,
		}
		b.custom_metrics_count += 1
	}
}

/*
Marks this benchmark as requiring zero heap allocations during the measured loop. It may be
called anywhere in the benchmark procedure, also after the loop.
*/
expect_zero_allocs :: proc "contextless" (b: ^Bencher) {
	b.expect_zero_alloc = true
}

// Records a second measurement call; the batch is reported as `.Measured_Twice`.
@(private)
_reject_second_measurement :: proc "contextless" (b: ^Bencher) -> bool {
	if b._started_sample {
		b._measured_twice = true
		return true
	}
	return false
}

/*
Returns the current parameter value when running inside a parameterized group (0 otherwise).
*/
@(require_results)
param :: proc "contextless" (b: ^Bencher) -> int {
	return b.param
}

/*
Returns the current thread count when running inside a multi-threaded group (1 otherwise).
*/
@(require_results)
threads :: proc "contextless" (b: ^Bencher) -> int {
	return b.threads > 0 ? b.threads : 1
}
