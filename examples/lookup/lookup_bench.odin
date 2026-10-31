package main

import obench "../../obench"
import "core:os"
import "core:slice"

// Runs obench from its own main through the library API (`Suite`, `Group`) to find where a
// linear scan, a binary search, and Odin's `map` cross over as the number of keys grows.

bench_linear_scan :: proc(b: ^obench.Bencher) {
	n := obench.param(b)
	keys := make([]u64, n)
	defer delete(keys)
	for i in 0 ..< n {
		keys[i] = u64(i * 7 + 3)
	}
	target := keys[n / 2]
	obench.set_items(b, 1)

	for obench.step(b) {
		q := obench.black_box(target)
		found := -1
		for k, idx in keys {
			if k == q {
				found = idx
				break
			}
		}
		_ = obench.black_box(found)
	}
}

bench_binary_search :: proc(b: ^obench.Bencher) {
	n := obench.param(b)
	keys := make([]u64, n)
	defer delete(keys)
	for i in 0 ..< n {
		keys[i] = u64(i * 7 + 3)
	}
	target := keys[n / 2]
	obench.set_items(b, 1)

	for obench.step(b) {
		q := obench.black_box(target)
		idx, _ := slice.binary_search(keys, q)
		_ = obench.black_box(idx)
	}
}

bench_hash_map :: proc(b: ^obench.Bencher) {
	n := obench.param(b)
	m := make(map[u64]int, n * 2)
	defer delete(m)
	for i in 0 ..< n {
		m[u64(i * 7 + 3)] = i
	}
	target := u64((n / 2) * 7 + 3)
	obench.set_items(b, 1)

	for obench.step(b) {
		q := obench.black_box(target)
		val := m[q]
		_ = obench.black_box(val)
	}
}

main :: proc() {
	s := obench.suite_create("Slice vs Binary Search vs Map")
	defer obench.suite_destroy(&s)

	g := obench.group_add(&s, "lookup_by_key")
	obench.group_params(g, []int{8, 64, 512, 4096})

	obench.group_bench(g, "linear_scan", bench_linear_scan, zero_alloc = true)
	obench.group_bench(g, "binary_search", bench_binary_search, zero_alloc = true)
	obench.group_bench(g, "odin_map", bench_hash_map, zero_alloc = true)

	if !obench.suite_run(&s) {
		os.exit(1)
	}
}
