package obench

import "base:intrinsics"
import "core:time"

/*
`true` when `intrinsics.read_cycle_counter` reads a CPU cycle counter (the x86 time-stamp
counter, which ticks at the nominal reference frequency).

On other architectures the intrinsic reads a fixed-frequency system timer instead (24 MHz
`CNTVCT_EL0` on Apple Silicon, for example), which carries no information beyond
wall-clock time, so obench does not report cycles there.
*/
CYCLE_COUNTER_SUPPORTED :: ODIN_ARCH == .amd64 || ODIN_ARCH == .i386

// Monotonic wall-clock and CPU cycle snapshot.
Timestamp :: struct {
	tick:   time.Tick,
	cycles: u64, // Always 0 when `CYCLE_COUNTER_SUPPORTED` is false.
}

// Calibrated properties of the benchmark clock.
Clock_Calibration :: struct {
	overhead_ns:       f64, // Cost of one timed window (two back-to-back `clock_now` calls).
	overhead_cycles:   f64, // Same as `overhead_ns`, in cycles. 0 without a cycle counter.
	resolution_ns:     f64, // Smallest observed non-zero tick difference.
	has_cycle_counter: bool, // Mirrors `CYCLE_COUNTER_SUPPORTED`.
}

// Captures the current monotonic timestamp and, when supported, the CPU cycle counter.
@(require_results)
clock_now :: #force_inline proc "contextless" () -> Timestamp {
	when CYCLE_COUNTER_SUPPORTED {
		return Timestamp{tick = time.tick_now(), cycles = u64(intrinsics.read_cycle_counter())}
	} else {
		return Timestamp{tick = time.tick_now()}
	}
}

// Computes elapsed nanoseconds and CPU cycles between two timestamps.
@(require_results)
clock_elapsed :: #force_inline proc "contextless" (
	start, end: Timestamp,
) -> (
	ns: i64,
	cycles: u64,
) {
	ns_diff := i64(time.tick_diff(start.tick, end.tick))
	if ns_diff < 0 {
		ns_diff = 0
	}
	cycle_diff: u64 = 0
	if end.cycles >= start.cycles {
		cycle_diff = end.cycles - start.cycles
	}
	return ns_diff, cycle_diff
}

/*
Measures the cost of a timed window (back-to-back `clock_now()` calls) and the timer
resolution. obench subtracts `overhead_ns` once per timed window from every sample.

The overhead is the mean window over a block of windows, and the lowest mean of several
blocks. A clock that ticks more coarsely than one window (24 MHz on Apple Silicon) reads
most single windows as 0, but the mean over many windows still converges to the true cost.
Taking the lowest block drops blocks hit by an interrupt.
*/
@(require_results)
clock_calibrate :: proc "contextless" () -> Clock_Calibration {
	BLOCKS :: 16
	WINDOWS_PER_BLOCK :: 256
	best_ns := max(f64)
	best_cycles := max(f64)

	for _ in 0 ..< BLOCKS {
		sum_ns: i64 = 0
		sum_cycles: u64 = 0
		for _ in 0 ..< WINDOWS_PER_BLOCK {
			t0 := clock_now()
			clobber_memory()
			t1 := clock_now()
			ns, cyc := clock_elapsed(t0, t1)
			sum_ns += ns
			sum_cycles += cyc
		}
		best_ns = min(best_ns, f64(sum_ns) / WINDOWS_PER_BLOCK)
		best_cycles = min(best_cycles, f64(sum_cycles) / WINDOWS_PER_BLOCK)
	}

	// Resolution: the smallest non-zero step of the monotonic clock.
	min_step: i64 = max(i64)
	for _ in 0 ..< 32 {
		start := time.tick_now()
		for spin := 0; spin < 1_000_000; spin += 1 {
			now := time.tick_now()
			diff := i64(time.tick_diff(start, now))
			if diff > 0 {
				if diff < min_step {
					min_step = diff
				}
				break
			}
		}
	}
	if min_step == max(i64) {
		min_step = 0
	}

	return Clock_Calibration {
		overhead_ns = best_ns,
		overhead_cycles = best_cycles,
		resolution_ns = f64(min_step),
		has_cycle_counter = CYCLE_COUNTER_SUPPORTED,
	}
}
