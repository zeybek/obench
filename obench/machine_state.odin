package obench

import "core:fmt"

/*
What obench can see of the machine's state when a suite runs, for the report and for the
notes in the terminal header. A field stays at its zero value where the OS doesn't say.
*/
Machine_State :: struct {
	// Frequency governor of CPU 0 on Linux, like "performance" or "powersave".
	governor:   string,
	// "on" or "off" when Linux says whether turbo or boost clocks are allowed.
	boost:      string,
	// "on" or "off" when Linux says whether simultaneous multithreading is active.
	smt:        string,
	// One-minute load average, on Linux and macOS.
	load_avg:   f64,
	// Running on battery power (Linux).
	on_battery: bool,
	// A hypervisor was found: the CPU's hypervisor flag or a virtual machine's firmware on
	// Linux, `kern.hv_vm_present` on macOS.
	vm:         bool,
}

/*
Reads the machine's state. Strings are allocated with `allocator`; free them with
`machine_state_destroy`.
*/
@(require_results)
read_machine_state :: proc(allocator := context.allocator) -> (st: Machine_State) {
	_read_machine_state_os(&st, allocator)
	return
}

machine_state_destroy :: proc(st: ^Machine_State, allocator := context.allocator) {
	delete(st.governor, allocator)
	delete(st.boost, allocator)
	delete(st.smt, allocator)
	st^ = {}
}

/*
One line about the machine for the terminal header: a warning when it makes timings less
steady (a governor other than `performance`, battery power, a load average of half the cores
or more), and a note when it's only worth knowing (turbo clocks, a virtual machine).
*/
Machine_Note :: struct {
	warning: bool,
	text:    string,
}

// The notes for `st` on a machine with `cores` logical cores, allocated with `allocator`.
@(require_results)
machine_notes :: proc(
	st: Machine_State,
	cores: int,
	allocator := context.temp_allocator,
) -> []Machine_Note {
	out := make([dynamic]Machine_Note, allocator)
	if st.governor != "" && st.governor != "performance" {
		text := fmt.aprintf(
			"the CPU governor is '%s'; 'performance' keeps the clock speed steady",
			st.governor,
			allocator = allocator,
		)
		append(&out, Machine_Note{true, text})
	}
	if st.on_battery {
		append(
			&out,
			Machine_Note{true, "running on battery power, which can lower the clock speed"},
		)
	}
	if st.load_avg >= max(1, f64(cores) / 2) {
		text := fmt.aprintf(
			"the load average is %.2f on %d cores, so other work is competing for the CPU",
			st.load_avg,
			cores,
			allocator = allocator,
		)
		append(&out, Machine_Note{true, text})
	}
	if st.boost == "on" {
		append(
			&out,
			Machine_Note {
				false,
				"turbo clocks are on, so the clock speed follows temperature and load",
			},
		)
	}
	if st.vm {
		append(
			&out,
			Machine_Note {
				false,
				"this is a virtual machine, where timings vary more than on bare metal",
			},
		)
	}
	return out[:]
}

// The affinity a thread had before `pin_thread`.
Thread_Pin :: struct {
	pinned: bool,
	mask:   [2]u64,
}

/*
Pins the calling thread to logical CPU `cpu` (`sched_setaffinity` on Linux,
`SetThreadAffinityMask` on Windows) and returns what `unpin_thread` needs to undo it. macOS
has no way to do this. `why` says what went wrong when `ok` is false. On Linux, threads
started later, like those of `run_parallel`, inherit the pin.
*/
@(require_results)
pin_thread :: proc(cpu: int) -> (previous: Thread_Pin, ok: bool, why: string) {
	if cpu < 0 {
		return {}, false, "the CPU number is negative"
	}
	return _pin_thread_os(cpu)
}

// Gives the calling thread back the affinity it had before `pin_thread`.
unpin_thread :: proc(previous: Thread_Pin) {
	if previous.pinned {
		_unpin_thread_os(previous)
	}
}

when ODIN_OS != .Linux && ODIN_OS != .Darwin && ODIN_OS != .Windows {
	@(private)
	_read_machine_state_os :: proc(st: ^Machine_State, allocator := context.allocator) {}

	@(private)
	_pin_thread_os :: proc(cpu: int) -> (Thread_Pin, bool, string) {
		return {}, false, "this OS can't pin a thread to a CPU"
	}

	@(private)
	_unpin_thread_os :: proc(previous: Thread_Pin) {}
}
