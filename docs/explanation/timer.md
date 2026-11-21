# The clock, its overhead, and the other counters

## What one timed window costs

Reading the clock takes time, and a timed window reads it twice. After each benchmark's warmup, obench times thousands of empty windows in blocks and takes the median of the block means, which drops the blocks an interrupt hit. It measures again for every benchmark because the cost depends on the core the benchmark has settled on: on an M2 a window costs about 14 ns on a performance core and about 22 ns on an efficiency core. obench subtracts it from every sample of that benchmark, once per window, and the `timer overhead` in the header is the last one it measured. The header also shows the clock's resolution, the smallest step it was seen to take: 41 ns on an Apple M2, whose clock ticks at 24 MHz. On Linux, obench reads `CLOCK_MONOTONIC_RAW` through libc, so the kernel's vDSO answers without a system call.

A sample has one window, plus one for every `pause`/`resume` pair, since each pair starts a new one. Three notes in the table come from this:

- `[near timer resolution]`: the benchmark's windows are less than 100 clock ticks long, so its times are quantized by 1% or more. An expensive `iter_batched` setup can cut calibration short, and so can many `pause`/`resume` pairs.
- `[clamped: 4/50 samples]`: 4 samples came out below the overhead of their windows and were counted as 0, so the times shown are too low.
- `[overhead-dominated]`: the overhead was more than 10% of the raw time.

The last two usually come from calling `pause` and `resume` around work that is smaller than the clock itself. Time a bigger piece of work, or move the setup out of the loop.

## The empty loop

After the benchmarks, obench times an empty `for obench.step(b) {}` loop, and the same loop with a `black_box` in its body, and shows the faster of the two in the header, like `empty loop 451.0 ps` on an M2. It times both because the empty one isn't always the fastest a `step` loop goes: on an M2 it takes about 0.7 ns per iteration and the one with the `black_box` about 0.46 ns. A single-threaded benchmark whose median is within 1.2 times of it gets `[near empty loop]`: there is hardly anything left of it, so the compiler most likely removed the work. Pass its input and its result through `black_box`. The report keeps the empty loop as `clock.empty_loop_ns`.

## The machine

The header warns about a machine that makes timings less steady: a CPU governor other than `performance`, battery power, or a load average of half the cores or more, on Linux, and the load average on macOS. It also notes turbo clocks and a virtual machine. The JSON report records all of it in `machine`, and a baseline measured on another CPU model, or under another `--machine` label, gets a warning. `--pin <cpu>` runs the benchmarks on one logical CPU on Linux and Windows, so the scheduler doesn't move them between cores. On Linux, the threads that `run_parallel` starts share that CPU.

## Cycles

On x86 the table has a `cycles` column with time-stamp counter ticks, which run at the CPU's nominal frequency, not at the frequency it actually ran at. On other architectures `read_cycle_counter` reads a fixed-frequency timer (24 MHz on Apple Silicon), so the column is hidden there.

## Hardware counters

On Linux, `--counters` reads the CPU's hardware counters around every sample with `perf_event_open`, and adds columns per operation for instructions, instructions per cycle, and branch and cache misses. Instructions barely move between runs, and the misses often explain why something got slower. The counters cover the whole batch, including the work between `pause` and `resume`, and only the thread that runs the benchmark, so a parallel benchmark gets none. Where the kernel doesn't allow them (`perf_event_paranoid` above 2, a container's seccomp filter, or a VM without a PMU), the header says why and the run goes on without them.

## Exact instruction counts

On Linux with Valgrind, `obench --instructions` runs every benchmark alone under Cachegrind twice, with N and 2N iterations (`--batch-size`, 100 by default), and reports `(I(2N) - I(N)) / N`. The process start and the setup outside the loop are the same in both runs, so they cancel out. Each run does nothing but those iterations: no clock calibration, warmup, statistics, or output (`Config.count_iterations`), so the count is the same every time. A benchmark that draws random input averages over the inputs its N iterations draw, so another N can give another count.
