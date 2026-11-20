package obench

import "core:fmt"
import win "core:sys/windows"

@(private)
_read_machine_state_os :: proc(st: ^Machine_State, allocator := context.allocator) {}

@(private)
_pin_thread_os :: proc(cpu: int) -> (Thread_Pin, bool, string) {
	if cpu >= 64 {
		return {}, false, "only CPUs 0 to 63 can be chosen"
	}
	old := win.SetThreadAffinityMask(win.GetCurrentThread(), win.DWORD_PTR(1) << uint(cpu))
	if old == 0 {
		return {}, false, fmt.tprintf("SetThreadAffinityMask failed (error %d)", win.GetLastError())
	}
	return Thread_Pin{pinned = true, mask = {u64(old), 0}}, true, ""
}

@(private)
_unpin_thread_os :: proc(previous: Thread_Pin) {
	_ = win.SetThreadAffinityMask(win.GetCurrentThread(), win.DWORD_PTR(previous.mask[0]))
}
