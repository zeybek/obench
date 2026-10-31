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
}

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
	_sample_start:        Timestamp,
	_accum_ns:            i64,
	_accum_cycles:        u64,
	_windows:             int, // Number of timed windows; each costs one clock overhead.

	// Per-operation throughput hints
	bytes_per_op:         u64,
	items_per_op:         u64,

	// Custom domain metrics
	custom_metrics:       [MAX_CUSTOM_METRICS]Custom_Metric,
	custom_metrics_count: int,

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
kept. Up to `MAX_CUSTOM_METRICS` distinct units are stored; `unit` is copied by the suite.
*/
report_metric :: proc "contextless" (b: ^Bencher, value: f64, unit: string) {
	for i in 0 ..< b.custom_metrics_count {
		if b.custom_metrics[i].unit == unit {
			b.custom_metrics[i].value = value
			return
		}
	}
	if b.custom_metrics_count < MAX_CUSTOM_METRICS {
		b.custom_metrics[b.custom_metrics_count] = Custom_Metric {
			unit  = unit,
			value = value,
		}
		b.custom_metrics_count += 1
	}
}

/*
Marks this benchmark as requiring zero heap allocations during the measured loop.
*/
expect_zero_allocs :: proc "contextless" (b: ^Bencher) {
	b.expect_zero_alloc = true
	if b._heap_counter != nil {
		b._heap_counter.enforce_zero_allocs = true
	}
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
