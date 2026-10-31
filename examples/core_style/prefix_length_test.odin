package prefix_length_benchmarks

// The benchmark from Odin's tests/benchmark/strings, written with obench and run by
// `odin test`:
//
//	odin test examples/core_style -o:speed
//
// It compares a byte-by-byte prefix length with core:strings.prefix_length on ASCII input and
// on input that ends in a multi-byte rune.

import obench "../../obench"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"

SIZES := [?]int{7, 16, 64, 256, 1024, 4096}

// Byte-by-byte scan that doesn't stop in the middle of a multi-byte rune.
plain_prefix_length :: proc "contextless" (a, b: string) -> int {
	n := 0
	limit := min(len(a), len(b))
	for n < limit && a[n] == b[n] {
		n += 1
	}
	for n > 0 && n < len(a) && !utf8.rune_start(a[n]) {
		n -= 1
	}
	return n
}

Prefix_Proc :: #type proc "contextless" (a, b: string) -> int

// Two equal strings of length `size` that differ at size/2 (ASCII), or that share a 4-byte
// rune starting at size/2 (Unicode).
@(private = "file")
run_prefix :: proc(b: ^obench.Bencher, prefix: Prefix_Proc, suffix: string) {
	size := obench.param(b)
	left := make([]u8, size)
	right := make([]u8, size)
	defer delete(left)
	defer delete(right)

	idx := size / 2
	if suffix != "" {
		copy(left[idx:], suffix)
		copy(right[idx:], suffix)
	} else {
		right[idx] = 'A'
	}

	obench.set_bytes(b, u64(size))
	for obench.step(b) {
		n := prefix(obench.black_box(string(left)), obench.black_box(string(right)))
		_ = obench.black_box(n)
	}
}

plain_ascii :: proc(b: ^obench.Bencher) {
	run_prefix(b, plain_prefix_length, "")
}

simd_ascii :: proc(b: ^obench.Bencher) {
	run_prefix(b, strings.prefix_length, "")
}

plain_unicode :: proc(b: ^obench.Bencher) {
	run_prefix(b, plain_prefix_length, "🦉")
}

simd_unicode :: proc(b: ^obench.Bencher) {
	run_prefix(b, strings.prefix_length, "🦉")
}

@(test)
prefix_length :: proc(t: ^testing.T) {
	// Both implementations must agree, on the kinds of input benchmarked below, before
	// their speed is worth comparing.
	cases := [?][2]string {
		{"abcdef", "abcxef"},
		{"🦉🦉", "🦉🐸"},
		{"a🦉", "a🦉"},
		{"", "x"},
		{"same", "same"},
	}
	for c in cases {
		testing.expect_value(t, plain_prefix_length(c[0], c[1]), strings.prefix_length(c[0], c[1]))
	}

	s := obench.suite_create("prefix_length")
	defer obench.suite_destroy(&s)

	ascii := obench.group_add(&s, "ascii")
	obench.group_params(ascii, SIZES[:])
	obench.group_bench(ascii, "plain", plain_ascii, zero_alloc = true)
	obench.group_bench(ascii, "core", simd_ascii, zero_alloc = true)

	unicode := obench.group_add(&s, "unicode")
	obench.group_params(unicode, SIZES[:])
	obench.group_bench(unicode, "plain", plain_unicode, zero_alloc = true)
	obench.group_bench(unicode, "core", simd_unicode, zero_alloc = true)

	obench.run_test(t, &s)
}
