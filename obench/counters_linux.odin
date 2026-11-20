package obench

import "core:fmt"
import "core:sys/linux"

// ioctl requests and the flag that applies them to the whole group, from linux/perf_event.h.
@(private = "file")
PERF_EVENT_IOC_ENABLE :: 0x2400
@(private = "file")
PERF_EVENT_IOC_DISABLE :: 0x2401
@(private = "file")
PERF_IOC_FLAG_GROUP :: 1

@(private)
_counter_group_open :: proc(kind: Counter_Kind) -> (g: Counter_Group, ok: bool, why: string) {
	g.fds = {-1, -1, -1, -1}
	for i in 0 ..< 4 {
		attr := linux.Perf_Event_Attr {
			size  = size_of(linux.Perf_Event_Attr),
			flags = {.Exclude_Kernel, .Exclude_HV},
		}
		switch kind {
		case .Hardware:
			attr.type = .HARDWARE
			hw := [4]linux.Perf_Hardware_Id {
				.INSTRUCTIONS,
				.CPU_CYCLES,
				.BRANCH_MISSES,
				.CACHE_MISSES,
			}
			attr.config.hw = hw[i]
		case .Software:
			attr.type = .SOFTWARE
			sw := [4]linux.Perf_Software_Id {
				.TASK_CLOCK,
				.PAGE_FAULTS,
				.CONTEXT_SWITCHES,
				.CPU_MIGRATIONS,
			}
			attr.config.sw = sw[i]
			// The kernel counts these itself, so excluding it would leave nothing.
			attr.flags = {}
		}
		leader := linux.Fd(-1)
		if i == 0 {
			attr.flags += {.Disabled}
			attr.read_format = {.GROUP, .TOTAL_TIME_ENABLED, .TOTAL_TIME_RUNNING}
		} else {
			leader = linux.Fd(g.fds[0])
		}
		fd, err := linux.perf_event_open(&attr, 0, -1, leader, {})
		if err != .NONE {
			if i == 0 {
				return {}, false, fmt.tprintf("perf_event_open failed with %v", err)
			}
			continue
		}
		g.fds[i] = i32(fd)
	}
	g.open = true
	linux.ioctl(linux.Fd(g.fds[0]), PERF_EVENT_IOC_ENABLE, PERF_IOC_FLAG_GROUP)
	return g, true, ""
}

@(private)
_counter_group_read :: proc(g: ^Counter_Group) -> (totals: Counter_Values, ok: bool) {
	// nr, time_enabled, time_running, then one value per counter that opened.
	buf: [3 + 4]u64
	n, err := linux.read(linux.Fd(g.fds[0]), ([^]u8)(&buf)[:size_of(buf)])
	if err != .NONE || n < 4 * size_of(u64) {
		return
	}
	count := min(int(buf[0]), 4)
	enabled, running := buf[1], buf[2]
	scale: f64 = 1
	if running > 0 && running < enabled {
		scale = f64(enabled) / f64(running)
	}
	slots := [4]^f64 {
		&totals.instructions,
		&totals.cycles,
		&totals.branch_misses,
		&totals.cache_misses,
	}
	next := 0
	for i in 0 ..< 4 {
		if g.fds[i] < 0 {
			continue
		}
		if next >= count {
			break
		}
		slots[i]^ = f64(buf[3 + next]) * scale
		next += 1
	}
	return totals, true
}

@(private)
_counter_group_close :: proc(g: ^Counter_Group) {
	linux.ioctl(linux.Fd(g.fds[0]), PERF_EVENT_IOC_DISABLE, PERF_IOC_FLAG_GROUP)
	for fd in g.fds {
		if fd >= 0 {
			linux.close(linux.Fd(fd))
		}
	}
}
