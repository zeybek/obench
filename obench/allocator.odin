package obench

import "base:intrinsics"
import "base:runtime"

/*
Lock-free allocation counter that wraps any `runtime.Allocator`.

Unlike `mem.Tracking_Allocator`, `Counting_Allocator` keeps no map of live allocations and
takes no lock: every counter is updated with relaxed atomics. Several threads may share one
instance as long as the backing allocator is itself thread-safe.

What is counted while not paused:
- `alloc_count`: `.Alloc` / `.Alloc_Non_Zeroed` calls, and `.Resize*` calls on a nil pointer.
- `resize_count`: `.Resize*` calls on an existing allocation with a non-zero new size.
- `bytes_allocated`: bytes requested by allocations plus the growth of resizes.
*/
Counting_Allocator :: struct {
	backing:              runtime.Allocator,
	alloc_count:          u64,
	resize_count:         u64,
	free_count:           u64,
	free_all_count:       u64,
	bytes_allocated:      u64,
	bytes_freed:          u64,
	current_bytes:        i64,
	peak_bytes:           i64,
	paused:               bool,
	enforce_zero_allocs:  bool,
	zero_alloc_violated:  bool,
	first_violation_loc:  runtime.Source_Code_Location,
	first_violation_size: int,
}

/*
Initializes a `Counting_Allocator` wrapping `backing`. The counter starts unpaused.
*/
counting_allocator_init :: proc "contextless" (
	c: ^Counting_Allocator,
	backing: runtime.Allocator,
) {
	c^ = Counting_Allocator {
		backing = backing,
	}
}

/*
Resets all counters on `c` while preserving configuration and the backing allocator.
*/
counting_allocator_reset :: proc "contextless" (c: ^Counting_Allocator) {
	intrinsics.atomic_store_explicit(&c.alloc_count, 0, .Relaxed)
	intrinsics.atomic_store_explicit(&c.resize_count, 0, .Relaxed)
	intrinsics.atomic_store_explicit(&c.free_count, 0, .Relaxed)
	intrinsics.atomic_store_explicit(&c.free_all_count, 0, .Relaxed)
	intrinsics.atomic_store_explicit(&c.bytes_allocated, 0, .Relaxed)
	intrinsics.atomic_store_explicit(&c.bytes_freed, 0, .Relaxed)
	intrinsics.atomic_store_explicit(&c.current_bytes, 0, .Relaxed)
	intrinsics.atomic_store_explicit(&c.peak_bytes, 0, .Relaxed)
	intrinsics.atomic_store_explicit(&c.zero_alloc_violated, false, .Relaxed)
	c.first_violation_loc = {}
	c.first_violation_size = 0
}

/*
Pauses (`true`) or resumes (`false`) counting. Allocation requests are always forwarded to
the backing allocator; only the bookkeeping is skipped while paused.
*/
counting_allocator_set_paused :: #force_inline proc "contextless" (
	c: ^Counting_Allocator,
	paused: bool,
) {
	if c != nil {
		intrinsics.atomic_store_explicit(&c.paused, paused, .Relaxed)
	}
}

/*
Returns a `runtime.Allocator` handle backed by `c`.
*/
@(require_results)
counting_allocator :: proc "contextless" (c: ^Counting_Allocator) -> runtime.Allocator {
	return runtime.Allocator{procedure = counting_allocator_proc, data = c}
}

// Adds the event counters of `src` into `dst` (used to merge per-thread counters).
@(private)
_counting_allocator_accumulate :: proc "contextless" (dst, src: ^Counting_Allocator) {
	if dst == nil || src == nil {
		return
	}
	_ = intrinsics.atomic_add_explicit(
		&dst.alloc_count,
		intrinsics.atomic_load_explicit(&src.alloc_count, .Relaxed),
		.Relaxed,
	)
	_ = intrinsics.atomic_add_explicit(
		&dst.resize_count,
		intrinsics.atomic_load_explicit(&src.resize_count, .Relaxed),
		.Relaxed,
	)
	_ = intrinsics.atomic_add_explicit(
		&dst.free_count,
		intrinsics.atomic_load_explicit(&src.free_count, .Relaxed),
		.Relaxed,
	)
	_ = intrinsics.atomic_add_explicit(
		&dst.free_all_count,
		intrinsics.atomic_load_explicit(&src.free_all_count, .Relaxed),
		.Relaxed,
	)
	_ = intrinsics.atomic_add_explicit(
		&dst.bytes_allocated,
		intrinsics.atomic_load_explicit(&src.bytes_allocated, .Relaxed),
		.Relaxed,
	)
	_ = intrinsics.atomic_add_explicit(
		&dst.bytes_freed,
		intrinsics.atomic_load_explicit(&src.bytes_freed, .Relaxed),
		.Relaxed,
	)
}

@(private = "file")
_update_peak_bytes :: #force_inline proc "contextless" (c: ^Counting_Allocator, cur: i64) {
	for {
		prev_peak := intrinsics.atomic_load_explicit(&c.peak_bytes, .Relaxed)
		if cur <= prev_peak {
			break
		}
		if _, ok := intrinsics.atomic_compare_exchange_weak_explicit(
			&c.peak_bytes,
			prev_peak,
			cur,
			.Relaxed,
			.Relaxed,
		); ok {
			break
		}
	}
}

@(private = "file")
_record_violation :: #force_inline proc "contextless" (
	c: ^Counting_Allocator,
	size: int,
	loc: runtime.Source_Code_Location,
) {
	if intrinsics.atomic_load_explicit(&c.enforce_zero_allocs, .Relaxed) {
		if _, ok := intrinsics.atomic_compare_exchange_strong_explicit(
			&c.zero_alloc_violated,
			false,
			true,
			.Acq_Rel,
			.Relaxed,
		); ok {
			c.first_violation_loc = loc
			c.first_violation_size = size
		}
	}
}

@(private = "file")
_record_growth :: #force_inline proc "contextless" (
	c: ^Counting_Allocator,
	bytes: int,
	loc: runtime.Source_Code_Location,
) {
	_ = intrinsics.atomic_add_explicit(&c.bytes_allocated, u64(bytes), .Relaxed)
	cur := intrinsics.atomic_add_explicit(&c.current_bytes, i64(bytes), .Relaxed) + i64(bytes)
	_update_peak_bytes(c, cur)
	_record_violation(c, bytes, loc)
}

@(private = "file")
_record_shrink :: #force_inline proc "contextless" (c: ^Counting_Allocator, bytes: int) {
	_ = intrinsics.atomic_add_explicit(&c.bytes_freed, u64(bytes), .Relaxed)
	cur := intrinsics.atomic_sub_explicit(&c.current_bytes, i64(bytes), .Relaxed) - i64(bytes)
	if cur < 0 {
		// Memory allocated while paused was released; clamp instead of going negative.
		intrinsics.atomic_store_explicit(&c.current_bytes, 0, .Relaxed)
	}
}

// `runtime.Allocator_Proc` behind `counting_allocator`. Forwards every request to the backing
// allocator and records it unless the counter is paused.
counting_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	c := (^Counting_Allocator)(allocator_data)
	if c == nil || c.backing.procedure == nil {
		return nil, .Invalid_Argument
	}

	data, err := c.backing.procedure(
		c.backing.data,
		mode,
		size,
		alignment,
		old_memory,
		old_size,
		loc,
	)
	if err != nil || intrinsics.atomic_load_explicit(&c.paused, .Relaxed) {
		return data, err
	}

	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if size > 0 {
			_ = intrinsics.atomic_add_explicit(&c.alloc_count, 1, .Relaxed)
			_record_growth(c, size, loc)
		}

	case .Resize, .Resize_Non_Zeroed:
		if old_memory == nil {
			if size > 0 {
				_ = intrinsics.atomic_add_explicit(&c.alloc_count, 1, .Relaxed)
				_record_growth(c, size, loc)
			}
		} else if size > 0 {
			_ = intrinsics.atomic_add_explicit(&c.resize_count, 1, .Relaxed)
			delta := size - old_size
			if delta > 0 {
				_record_growth(c, delta, loc)
			} else if delta < 0 {
				_record_shrink(c, -delta)
			}
		} else if old_size > 0 {
			// Resizing to zero frees the allocation.
			_ = intrinsics.atomic_add_explicit(&c.free_count, 1, .Relaxed)
			_record_shrink(c, old_size)
		}

	case .Free:
		if old_memory != nil {
			_ = intrinsics.atomic_add_explicit(&c.free_count, 1, .Relaxed)
			if old_size > 0 {
				_record_shrink(c, old_size)
			}
		}

	case .Free_All:
		_ = intrinsics.atomic_add_explicit(&c.free_all_count, 1, .Relaxed)
		prev_cur := intrinsics.atomic_exchange_explicit(&c.current_bytes, 0, .Relaxed)
		if prev_cur > 0 {
			_ = intrinsics.atomic_add_explicit(&c.bytes_freed, u64(prev_cur), .Relaxed)
		}

	case .Query_Features, .Query_Info:
	// Metadata queries are not counted.
	}

	return data, err
}
