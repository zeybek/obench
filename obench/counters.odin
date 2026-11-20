package obench

/*
Hardware counters of a benchmark per operation, from Linux's `perf_event_open`
(`Config.counters`, `--counters`): the median over the samples of each counter's change
during one sample, divided by the batch size. They cover the whole batch, including the
untimed work between `pause` and `resume`, so for a benchmark with setup they come out higher
than the time alone suggests. A counter the CPU doesn't have stays 0.
*/
Counter_Values :: struct {
	instructions:  f64,
	cycles:        f64,
	branch_misses: f64,
	cache_misses:  f64,
}

// Which events `counter_group_open` counts.
Counter_Kind :: enum {
	// Instructions, CPU cycles, branch misses, and cache misses, in user space.
	Hardware,
	// The kernel's software events in the same four slots: task clock (ns), page faults,
	// context switches, and CPU migrations. They work where no hardware counters are
	// exposed, as in most virtual machines, which makes them useful for testing.
	Software,
}

/*
An open group of four counters for the calling thread. Read it with `counter_group_read` and
close it with `counter_group_close`.
*/
Counter_Group :: struct {
	fds:  [4]i32, // -1 for a counter that couldn't be opened
	open: bool,
}

/*
Opens and starts the counters of `kind` for the calling thread, on Linux. `ok` is false with
the reason in `why` when the kernel refuses (`perf_event_paranoid`, a container's seccomp
filter, a VM without a PMU) or on another OS. A group whose first counter opened but some
others didn't still works, with those counters at 0.
*/
@(require_results)
counter_group_open :: proc(
	kind := Counter_Kind.Hardware,
) -> (
	g: Counter_Group,
	ok: bool,
	why: string,
) {
	return _counter_group_open(kind)
}

/*
The counters' totals since `counter_group_open`, scaled up when the kernel had to share the
hardware with other groups for part of the time.
*/
@(require_results)
counter_group_read :: proc(g: ^Counter_Group) -> (totals: Counter_Values, ok: bool) {
	if !g.open {
		return
	}
	return _counter_group_read(g)
}

counter_group_close :: proc(g: ^Counter_Group) {
	if g.open {
		_counter_group_close(g)
	}
	g^ = {}
}

when ODIN_OS != .Linux {
	@(private)
	_counter_group_open :: proc(kind: Counter_Kind) -> (Counter_Group, bool, string) {
		return {}, false, "hardware counters need Linux"
	}

	@(private)
	_counter_group_read :: proc(g: ^Counter_Group) -> (Counter_Values, bool) {
		return {}, false
	}

	@(private)
	_counter_group_close :: proc(g: ^Counter_Group) {}
}
