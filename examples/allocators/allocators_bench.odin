package allocators_bench

import obench "../../obench"
import "core:container/small_array"
import "core:mem"

// Compares Odin's allocator strategies when building a dynamic batch of 64 items:
// 1. Default OS heap allocator (`context.allocator`)
// 2. Pre-allocated `mem.Arena`
// 3. `context.temp_allocator`
// 4. Stack-allocated `small_array.Small_Array` (@zero_alloc)

bench_batch_build__heap :: proc(b: ^obench.Bencher) {
	obench.set_items(b, 64)
	for obench.step(b) {
		arr := make([dynamic]u64, 0, 16)
		for i in 0 ..< 64 {
			append(&arr, u64(i))
		}
		obench.keep_alive(&arr[0])
		delete(arr)
	}
}

bench_batch_build__temp_allocator :: proc(b: ^obench.Bencher) {
	obench.set_items(b, 64)
	for obench.step(b) {
		arr := make([dynamic]u64, 0, 16, context.temp_allocator)
		for i in 0 ..< 64 {
			append(&arr, u64(i))
		}
		obench.keep_alive(&arr[0])
	}
}

// @zero_alloc
bench_batch_build__arena_preallocated :: proc(b: ^obench.Bencher) {
	backing := make([]byte, 16 * 1024)
	defer delete(backing)

	arena: mem.Arena
	mem.arena_init(&arena, backing)
	arena_alloc := mem.arena_allocator(&arena)

	obench.set_items(b, 64)
	for obench.step(b) {
		mem.arena_free_all(&arena)
		arr := make([dynamic]u64, 0, 64, arena_alloc)
		for i in 0 ..< 64 {
			append(&arr, u64(i))
		}
		obench.keep_alive(&arr[0])
	}
}

// @zero_alloc
bench_batch_build__small_array_stack :: proc(b: ^obench.Bencher) {
	obench.set_items(b, 64)
	for obench.step(b) {
		sa: small_array.Small_Array(64, u64)
		for i in 0 ..< 64 {
			small_array.append(&sa, u64(i))
		}
		obench.keep_alive(&sa)
	}
}
