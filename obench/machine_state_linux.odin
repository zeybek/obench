package obench

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"

@(private)
_read_machine_state_os :: proc(st: ^Machine_State, allocator := context.allocator) {
	st.governor = _read_line("/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor", allocator)
	if no_turbo := _read_line("/sys/devices/system/cpu/intel_pstate/no_turbo"); no_turbo != "" {
		st.boost = strings.clone("off" if no_turbo == "1" else "on", allocator)
	} else if boost := _read_line("/sys/devices/system/cpu/cpufreq/boost"); boost != "" {
		st.boost = strings.clone("on" if boost == "1" else "off", allocator)
	}
	if smt := _read_line("/sys/devices/system/cpu/smt/active"); smt != "" {
		st.smt = strings.clone("on" if smt == "1" else "off", allocator)
	}
	if load := _read_line("/proc/loadavg"); load != "" {
		first, _, _ := strings.partition(load, " ")
		st.load_avg, _ = strconv.parse_f64(first)
	}
	st.on_battery = _on_battery()
	st.vm = _in_vm()
}

// The first line of a small file, trimmed, or "" when it can't be read.
@(private = "file")
_read_line :: proc(path: string, allocator := context.temp_allocator) -> string {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return ""
	}
	line, _, _ := strings.partition(string(data), "\n")
	line = strings.trim_space(line)
	if line == "" {
		return ""
	}
	return strings.clone(line, allocator)
}

@(private = "file")
_on_battery :: proc() -> bool {
	entries, err := os.read_all_directory_by_path(
		"/sys/class/power_supply",
		context.temp_allocator,
	)
	if err != nil {
		return false
	}
	has_battery, on_mains := false, false
	for e in entries {
		switch _read_line(fmt.tprintf("%s/type", e.fullpath)) {
		case "Battery":
			has_battery = true
		case "Mains", "USB":
			if _read_line(fmt.tprintf("%s/online", e.fullpath)) == "1" {
				on_mains = true
			}
		}
	}
	return has_battery && !on_mains
}

@(private = "file")
_in_vm :: proc() -> bool {
	if os.exists("/sys/hypervisor/type") {
		return true
	}
	firmware := []string{"/sys/class/dmi/id/product_name", "/sys/class/dmi/id/sys_vendor"}
	known := []string{"Virtual Machine", "VirtualBox", "VMware", "KVM", "QEMU", "Xen", "Bochs"}
	for path in firmware {
		name := _read_line(path)
		for vm in known {
			if strings.contains(name, vm) {
				return true
			}
		}
	}
	when ODIN_ARCH == .amd64 || ODIN_ARCH == .i386 {
		data, err := os.read_entire_file("/proc/cpuinfo", context.temp_allocator)
		if err == nil {
			text := string(data)
			for line in strings.split_lines_iterator(&text) {
				if strings.has_prefix(line, "flags") {
					return strings.contains(line, " hypervisor")
				}
			}
		}
	}
	return false
}

@(private)
_pin_thread_os :: proc(cpu: int) -> (Thread_Pin, bool, string) {
	if cpu >= 128 {
		return {}, false, "only CPUs 0 to 127 can be chosen"
	}
	old: linux.Cpu_Set
	if _, err := linux.sched_getaffinity(0, size_of(old), &old); err != .NONE {
		return {}, false, fmt.tprintf("sched_getaffinity failed: %v", err)
	}
	mask := linux.Cpu_Set{cpu}
	if _, err := linux.sched_setaffinity(0, size_of(mask), &mask); err != .NONE {
		return {}, false, fmt.tprintf("sched_setaffinity failed: %v", err)
	}
	return Thread_Pin{pinned = true, mask = transmute([2]u64)old}, true, ""
}

@(private)
_unpin_thread_os :: proc(previous: Thread_Pin) {
	mask := transmute(linux.Cpu_Set)previous.mask
	_, _ = linux.sched_setaffinity(0, size_of(mask), &mask)
}
