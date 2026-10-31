package obench

import "base:intrinsics"

/*
Optimization barrier for values.

The compiler cannot see through `black_box`: the input value must be computed (it is
written with a volatile store), and the returned value cannot be constant-folded (it is
read back with a volatile load).

For scalars, enums, booleans, and SIMD vectors this is a stack store plus load with no
procedure call and no shared memory, so it is safe and cheap inside multi-threaded
`run_parallel` bodies. Other types (structs, arrays, slices, pointers, ...) also go through
an opaque call, so any memory they reference is treated as read and written.

Inputs:
- val: The value to hide from the optimizer.

Returns:
- The same value, which the optimizer must treat as unknown.
*/
@(require_results)
black_box :: #force_inline proc "contextless" (val: $T) -> T {
	NUMBER :: intrinsics.type_is_numeric(T) || intrinsics.type_is_simd_vector(T)
	SCALAR :: NUMBER || intrinsics.type_is_boolean(T) || intrinsics.type_is_enum(T)
	when SCALAR {
		local: T
		intrinsics.volatile_store(&local, val)
		return intrinsics.volatile_load(&local)
	} else {
		local := val
		_escape(&local)
		return local
	}
}

/*
Forces the compiler to assume the memory pointed to by `ptr` is read and possibly modified,
without copying the value.

This costs one opaque procedure call. It touches no shared memory, so concurrent use from
`run_parallel` bodies does not cause cache-line contention.
*/
keep_alive :: #force_inline proc "contextless" (ptr: ^$T) {
	_escape(rawptr(ptr))
}

/*
Compiler-only memory barrier: prevents the compiler from reordering memory accesses across
the call. It emits no CPU fence instruction.
*/
clobber_memory :: #force_inline proc "contextless" () {
	intrinsics.atomic_signal_fence(.Seq_Cst)
}

// `optimization_mode = "none"` makes the call opaque: the optimizer cannot inline it or
// infer attributes for it, so callers must assume it reads and writes anything reachable
// from `ptr`. The sink is a stack local on purpose: a shared global would make every
// thread write the same cache line.
@(private = "file", optimization_mode = "none")
_escape :: proc "contextless" (ptr: rawptr) {
	sink: rawptr
	intrinsics.volatile_store(&sink, ptr)
}
