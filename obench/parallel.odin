package obench

import "base:intrinsics"
import "base:runtime"
import "core:sync"
import "core:thread"

// Padding used to keep hot shared counters on their own cache line
// (128 bytes covers the 128-byte lines of Apple Silicon as well as 64-byte x86 lines).
@(private = "file")
CACHE_LINE_PAD :: 128

/*
Per-worker state passed to `run_parallel` callbacks (modeled after Go's `testing.PB`).
*/
Parallel_Bencher :: struct {
	bencher:      ^Bencher,
	thread_index: int,
	num_threads:  int,
	user_ptr:     rawptr,
	_shared_rem:  ^int,
	_local_rem:   int,
	_stride:      int,
}

/*
Returns `true` while there are iterations left in a `run_parallel` benchmark.

Each worker claims a stride of iterations from a shared atomic counter and counts it down
locally, so the shared counter is touched about 32 times per thread per sample instead of
once per iteration.
*/
@(require_results)
parallel_next :: #force_inline proc "contextless" (pb: ^Parallel_Bencher) -> bool {
	if pb._local_rem > 0 {
		pb._local_rem -= 1
		return true
	}

	stride := pb._stride
	prev := intrinsics.atomic_sub_explicit(pb._shared_rem, stride, .Relaxed)
	if prev <= 0 {
		return false
	}

	claimed := min(prev, stride)
	pb._local_rem = claimed - 1
	return true
}

@(private = "file")
_Parallel_Shared :: struct {
	bencher:     ^Bencher,
	body:        proc(pb: ^Parallel_Bencher),
	num_threads: int,
	stride:      int,
	logger:      runtime.Logger,
	ready_bar:   sync.Barrier,
	_pad0:       [CACHE_LINE_PAD]u8,
	shared_rem:  int,
	_pad1:       [CACHE_LINE_PAD]u8,
	go:          bool,
	done:        int,
	_pad2:       [CACHE_LINE_PAD]u8,
}

// Spins briefly, then yields, until `flag` becomes true. Spinning keeps the release latency
// far below a futex wake-up, which would otherwise be counted inside the timed window.
@(private = "file")
_wait_for_flag :: proc(flag: ^bool) {
	spins := 0
	for !intrinsics.atomic_load_explicit(flag, .Acquire) {
		spins += 1
		if spins < 4096 {
			intrinsics.cpu_relax()
		} else {
			thread.yield()
		}
	}
}

@(private = "file")
_wait_for_count :: proc(counter: ^int, target: int) {
	spins := 0
	for intrinsics.atomic_load_explicit(counter, .Acquire) < target {
		spins += 1
		if spins < 4096 {
			intrinsics.cpu_relax()
		} else {
			thread.yield()
		}
	}
}

@(private = "file")
_parallel_worker_proc :: proc(t: ^thread.Thread) {
	shared := (^_Parallel_Shared)(t.data)
	b := shared.bencher

	context.logger = shared.logger
	if b._heap_counter != nil {
		context.allocator = counting_allocator(b._heap_counter)
	}

	// Each worker counts its own temp allocations (its temp allocator is thread-local)
	// and adds them to the benchmark's temp counter at the end.
	temp_counter: Counting_Allocator
	counting_allocator_init(&temp_counter, context.temp_allocator)
	counting_allocator_set_paused(&temp_counter, true)
	context.temp_allocator = counting_allocator(&temp_counter)

	pb := Parallel_Bencher {
		bencher      = b,
		thread_index = t.user_index,
		num_threads  = shared.num_threads,
		user_ptr     = b.user_ptr,
		_shared_rem  = &shared.shared_rem,
		_local_rem   = 0,
		_stride      = shared.stride,
	}

	sync.barrier_wait(&shared.ready_bar)
	_wait_for_flag(&shared.go)

	counting_allocator_set_paused(&temp_counter, b._temp_counter == nil)
	shared.body(&pb)
	counting_allocator_set_paused(&temp_counter, true)

	_counting_allocator_accumulate(b._temp_counter, &temp_counter)
	_ = intrinsics.atomic_add_explicit(&shared.done, 1, .Release)
}

/*
Executes `body` concurrently on `num_threads` OS threads (default: the group's thread
count from `@threads(...)`, or 4) that share the benchmark's iteration budget.

Thread creation and teardown happen outside the timed window. All threads wait at a barrier,
then spin on a start flag that the main thread sets right after starting the clock; the clock
stops once every thread has finished its share. Heap allocations made by any worker go
through the benchmark's counting allocator (the backing `context.allocator` must be
thread-safe), and each worker's temp allocations are counted as well.

The reported time per operation is wall time divided by the total iteration count, so
perfect scaling halves the per-operation time each time the thread count doubles.
*/
run_parallel :: proc(b: ^Bencher, body: proc(pb: ^Parallel_Bencher), num_threads := 0) {
	threads_to_use := num_threads
	if threads_to_use <= 0 {
		threads_to_use = b.threads > 0 ? b.threads : 4
	}

	total_iters := max(b.remaining_iters, 1)
	b._started_sample = true
	b._paused = true
	_set_counters_paused(b, true)

	defer {
		_set_counters_paused(b, true)
		b._windows += 1
		b.remaining_iters = 0
		b._finished = true
	}

	// Single-threaded fast path: no thread spawn, no synchronization.
	if threads_to_use == 1 {
		shared_rem := total_iters
		pb := Parallel_Bencher {
			bencher      = b,
			thread_index = 0,
			num_threads  = 1,
			user_ptr     = b.user_ptr,
			_shared_rem  = &shared_rem,
			_local_rem   = 0,
			_stride      = max(total_iters / 16, 1),
		}

		_set_counters_paused(b, false)
		clobber_memory()
		t0 := clock_now()

		body(&pb)

		t1 := clock_now()
		clobber_memory()
		_set_counters_paused(b, true)

		ns, cyc := clock_elapsed(t0, t1)
		b._accum_ns += ns
		b._accum_cycles += cyc
		return
	}

	shared := new(_Parallel_Shared)
	defer free(shared)
	shared^ = _Parallel_Shared {
		bencher     = b,
		body        = body,
		num_threads = threads_to_use,
		stride      = max(total_iters / (threads_to_use * 32), 1),
		logger      = context.logger,
		shared_rem  = total_iters,
	}
	sync.barrier_init(&shared.ready_bar, threads_to_use)

	workers := make([]^thread.Thread, threads_to_use - 1)
	defer delete(workers)

	for i in 0 ..< threads_to_use - 1 {
		w := thread.create(_parallel_worker_proc)
		w.data = shared
		w.user_index = i + 1
		workers[i] = w
		thread.start(w)
	}

	// The main thread participates as worker 0.
	pb0 := Parallel_Bencher {
		bencher      = b,
		thread_index = 0,
		num_threads  = threads_to_use,
		user_ptr     = b.user_ptr,
		_shared_rem  = &shared.shared_rem,
		_local_rem   = 0,
		_stride      = shared.stride,
	}

	// Wait until every worker thread is running.
	sync.barrier_wait(&shared.ready_bar)

	_set_counters_paused(b, false)
	clobber_memory()
	t0 := clock_now()
	intrinsics.atomic_store_explicit(&shared.go, true, .Release)

	body(&pb0)
	_wait_for_count(&shared.done, threads_to_use - 1)

	t1 := clock_now()
	clobber_memory()
	_set_counters_paused(b, true)

	for w in workers {
		thread.join(w)
		thread.destroy(w)
	}

	ns, cyc := clock_elapsed(t0, t1)
	b._accum_ns += ns
	b._accum_cycles += cyc
}
