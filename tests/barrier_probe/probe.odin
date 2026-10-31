// Small exported procedures compiled to assembly by scripts/check_barriers.sh, which checks
// that the optimizer keeps what black_box and keep_alive promise to keep.
package barrier_probe

import obench "../../obench"

// The 41 must survive; folding would leave only 42.
@(export, link_name = "probe_const_fold")
probe_const_fold :: proc "c" () -> int {
	return obench.black_box(41) + 1
}

// Stores into a local array that is never read: keep_alive must keep them.
@(export, link_name = "probe_stores_kept")
probe_stores_kept :: proc "c" () {
	arr: [8]int
	for i in 0 ..< 8 {
		arr[i] = i * i
	}
	obench.keep_alive(&arr)
}

// The same stores without a barrier: the optimizer is expected to remove them.
@(export, link_name = "probe_stores_dropped")
probe_stores_dropped :: proc "c" () {
	arr: [8]int
	for i in 0 ..< 8 {
		arr[i] = i * i
	}
}

main :: proc() {
	_ = probe_const_fold()
	probe_stores_kept()
	probe_stores_dropped()
}
