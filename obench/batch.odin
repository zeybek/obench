package obench

/*
Controls how many inputs are pre-generated at once in `iter_batched` and `iter_with_large_drop`
(modeled after Rust Criterion's `BatchSize`).
*/
Batch_Mode :: enum {
	// Pre-generates up to 4096 inputs per batch. For small inputs (slices, small structs).
	Small_Input,
	// Pre-generates up to 128 inputs per batch. For larger heap structures (maps, trees), so
	// the batch fits in L2/L3 cache and doesn't exhaust RAM.
	Large_Input,
	// Generates 1 input per timed window. Use when each input is megabytes in size.
	Per_Iteration,
}

@(private = "file")
_batch_mode_limit :: proc "contextless" (mode: Batch_Mode) -> int {
	switch mode {
	case .Small_Input:
		return 4096
	case .Large_Input:
		return 128
	case .Per_Iteration:
		return 1
	}
	return 1
}

/*
Benchmarks a destructive or in-place `routine` (such as sorting a slice, mutating a tree,
or popping from a queue) without reading the clock on every iteration.

For each chunk of iterations:
1. `setup(b)` is called `chunk_len` times while timers and allocation counters are paused.
2. Timers and allocation counters are enabled, and `routine(&inputs[i])` runs in a tight
   loop over all `chunk_len` inputs.
3. Timers and allocation counters are paused again, and `teardown(&inputs[i])` (if non-nil)
   is called on each input to release resources.

Each chunk is one timed window; obench subtracts the clock overhead once per chunk.
*/
iter_batched :: proc(
	b: ^Bencher,
	setup: proc(b: ^Bencher) -> $T,
	routine: proc(input: ^T),
	teardown: proc(input: ^T) = nil,
	mode: Batch_Mode = .Small_Input,
) {
	if _reject_second_measurement(b) {
		return
	}
	total := max(b.remaining_iters, 1)
	chunk_cap := min(total, _batch_mode_limit(mode))

	b._started_sample = true
	b._paused = true
	_set_counters_paused(b, true)

	// Chunk storage is allocated while the counters are paused.
	inputs := make([]T, chunk_cap)
	defer {
		_set_counters_paused(b, true)
		delete(inputs)
		b.remaining_iters = 0
		b._finished = true
	}

	remaining := total
	for remaining > 0 {
		k := min(remaining, chunk_cap)

		// 1. Untimed setup
		for i in 0 ..< k {
			inputs[i] = setup(b)
		}

		// 2. Timed, allocation-counted hot loop
		_set_counters_paused(b, false)
		b._windows += 1
		clobber_memory()
		t0 := clock_now()

		for i in 0 ..< k {
			routine(&inputs[i])
		}

		t1 := clock_now()
		clobber_memory()
		_set_counters_paused(b, true)

		ns, cyc := clock_elapsed(t0, t1)
		b._accum_ns += ns
		b._accum_cycles += cyc

		// 3. Untimed teardown
		if teardown != nil {
			for i in 0 ..< k {
				teardown(&inputs[i])
			}
		}

		remaining -= k
	}
}

/*
Benchmarks a producer `routine` whose result `R` is destroyed by `drop` outside the timed
window and allocation counters.
*/
iter_with_large_drop :: proc(
	b: ^Bencher,
	routine: proc() -> $R,
	drop: proc(val: ^R),
	mode: Batch_Mode = .Small_Input,
) {
	if _reject_second_measurement(b) {
		return
	}
	total := max(b.remaining_iters, 1)
	chunk_cap := min(total, _batch_mode_limit(mode))

	b._started_sample = true
	b._paused = true
	_set_counters_paused(b, true)

	outputs := make([]R, chunk_cap)
	defer {
		_set_counters_paused(b, true)
		delete(outputs)
		b.remaining_iters = 0
		b._finished = true
	}

	remaining := total
	for remaining > 0 {
		k := min(remaining, chunk_cap)

		// Timed producer phase
		_set_counters_paused(b, false)
		b._windows += 1
		clobber_memory()
		t0 := clock_now()

		for i in 0 ..< k {
			outputs[i] = routine()
		}

		t1 := clock_now()
		clobber_memory()
		_set_counters_paused(b, true)

		ns, cyc := clock_elapsed(t0, t1)
		b._accum_ns += ns
		b._accum_cycles += cyc

		// Untimed drop phase
		if drop != nil {
			for i in 0 ..< k {
				drop(&outputs[i])
			}
		}

		remaining -= k
	}
}
