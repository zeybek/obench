package parallel_bench

import obench "../../obench"
import "base:intrinsics"
import "core:sync"

// Contention between threads with `obench.run_parallel`: a thread-local counter, an atomic
// add, and a mutex, each on 1, 2, and 4 OS threads through `@threads(1, 2, 4)`.

@(private = "file")
g_atomic_counter: i64

@(private = "file")
g_mutex: sync.Mutex
@(private = "file")
g_mutex_counter: i64

// @zero_alloc
// @threads(1, 2, 4)
bench_contention__thread_local :: proc(b: ^obench.Bencher) {
	obench.set_items(b, 1)
	obench.run_parallel(b, proc(pb: ^obench.Parallel_Bencher) {
		local_sum: i64 = 0
		for obench.parallel_next(pb) {
			local_sum += obench.black_box(i64(1))
		}
		_ = obench.black_box(local_sum)
	})
}

// @zero_alloc
// @threads(1, 2, 4)
bench_contention__atomic_add :: proc(b: ^obench.Bencher) {
	obench.set_items(b, 1)
	intrinsics.atomic_store_explicit(&g_atomic_counter, 0, .Relaxed)
	obench.run_parallel(b, proc(pb: ^obench.Parallel_Bencher) {
		for obench.parallel_next(pb) {
			_ = intrinsics.atomic_add_explicit(&g_atomic_counter, 1, .Relaxed)
		}
	})
}

// @zero_alloc
// @threads(1, 2, 4)
bench_contention__mutex_lock :: proc(b: ^obench.Bencher) {
	obench.set_items(b, 1)
	g_mutex_counter = 0
	obench.run_parallel(b, proc(pb: ^obench.Parallel_Bencher) {
		for obench.parallel_next(pb) {
			if sync.mutex_guard(&g_mutex) {
				g_mutex_counter += 1
			}
		}
	})
}
