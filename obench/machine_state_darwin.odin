package obench

import "core:c"
import "core:sys/unix"

@(private)
_read_machine_state_os :: proc(st: ^Machine_State, allocator := context.allocator) {
	Loadavg :: struct {
		ldavg:  [3]u32,
		fscale: c.long,
	}
	load: Loadavg
	if unix.sysctlbyname("vm.loadavg", &load) && load.fscale > 0 {
		st.load_avg = f64(load.ldavg[0]) / f64(load.fscale)
	}
	present: i32
	if unix.sysctlbyname("kern.hv_vm_present", &present) {
		st.vm = present != 0
	}
}

@(private)
_pin_thread_os :: proc(cpu: int) -> (Thread_Pin, bool, string) {
	return {}, false, "macOS can't pin a thread to a CPU"
}

@(private)
_unpin_thread_os :: proc(previous: Thread_Pin) {}
