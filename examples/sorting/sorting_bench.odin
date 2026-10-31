package sorting_bench

import obench "../../obench"
import "core:slice"

// Sorting in place destroys the input, so every iteration needs a fresh unsorted copy.
// `obench.iter_batched` builds those copies with the clock and the allocation counters
// paused.

@(private = "file")
make_reverse_slice :: proc(b: ^obench.Bencher) -> []int {
	n := obench.param(b)
	arr := make([]int, n)
	for i in 0 ..< n {
		// Deterministic pseudo-shuffled sequence
		arr[i] = int((u64(n - i) * 2654435761) & 0xFFFF)
	}
	return arr
}

@(private = "file")
free_int_slice :: proc(arr: ^[]int) {
	delete(arr^)
}

@(private = "file")
insertion_sort :: proc(arr: ^[]int) {
	s := arr^
	for i := 1; i < len(s); i += 1 {
		key := s[i]
		j := i - 1
		for j >= 0 && s[j] > key {
			s[j + 1] = s[j]
			j -= 1
		}
		s[j + 1] = key
	}
	obench.keep_alive(&s[0])
}

@(private = "file")
std_quicksort :: proc(arr: ^[]int) {
	s := arr^
	slice.sort(s)
	obench.keep_alive(&s[0])
}

// @zero_alloc
// @params(32, 128, 512)
bench_in_place_sort__insertion_sort :: proc(b: ^obench.Bencher) {
	n := obench.param(b)
	obench.set_items(b, u64(n))
	obench.iter_batched(b, make_reverse_slice, insertion_sort, free_int_slice)
}

// @zero_alloc
// @params(32, 128, 512)
bench_in_place_sort__slice_sort :: proc(b: ^obench.Bencher) {
	n := obench.param(b)
	obench.set_items(b, u64(n))
	obench.iter_batched(b, make_reverse_slice, std_quicksort, free_int_slice)
}
