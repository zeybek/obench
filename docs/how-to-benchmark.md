# How to benchmark Odin code

Getting a number out of a benchmark is easy. Getting one that still holds when you run it again, on the same code, takes a few habits. This page goes through them with obench as the example, but they apply to any harness, including a `time.tick_now` loop you wrote yourself.

The questions on the Odin forum are often about exactly this. In [one thread](https://forum.odin-lang.org/t/questions-about-sring-performance-in-odin-vs-c/2660) someone compared a hexdumper in Odin and C with the shell's `time`, and the replies asked what the workload was, suggested repeated warm iterations, and suggested building the output in memory so formatting is measured apart from I/O. Those three replies are most of this page.

## Build it the way you ship it

Benchmark an optimized build. obench builds with `-o:speed` unless you pass `-o`, and its report warns when a suite was built with `-o:none`, `-o:minimal` or `-debug`, because those times say little about the release build. Bounds checks cost time too, so if you ship with `-no-bounds-check`, benchmark with `--no-bounds-check`, and don't compare a run with them against one without.

## Warm up, then take many samples

The first iterations pay for cold caches, page faults and a CPU that hasn't raised its clock yet. obench runs each benchmark for 40 ms before it measures, then takes 50 samples, each a batch of iterations long enough to last at least 1 ms. `-w` and `-n` change the warmup and the sample count.

Many samples from one run still come from one process, and two processes running the same code can differ more than the samples inside either of them. On an M2 I ran `examples/lookup` four times in a row without changing anything and compared every pair of runs: 47 of 72 comparisons came out as faster or slower, and `odin_map[64]` went from 4.33 ns to 3.29 ns between two runs. Before you believe a change of a few percent, run both sides more than once, on the same machine, back to back. Repetition across processes and interleaved A/B runs are planned for obench itself ([#30](https://github.com/zeybek/obench/issues/30), [#31](https://github.com/zeybek/obench/issues/31)).

## Make sure the work happens

The compiler deletes work whose result nobody uses, and it computes at compile time whatever it can see through. Pass results through `black_box`, and inputs too when the compiler could otherwise know them:

```odin
bench_sum :: proc(b: ^obench.Bencher) {
	values: [64]int
	for i in 0 ..< 64 {
		values[i] = i
	}
	for obench.step(b) {
		obench.keep_alive(&values) // the array may have changed, so it has to be read again
		total := 0
		for v in values {
			total += v
		}
		_ = obench.black_box(total)
	}
}
```

Without the `keep_alive` line, the sum of a constant array is folded. On an M2 that version measured 0.48 to 0.78 ns at p50, faster than an empty `for obench.step(b) {}` loop in the same runs (0.81 to 2.25 ns). With it, the sum took 3.75 to 4.44 ns. A result below the empty loop is always a sign that something was optimized away. `black_box` copies its argument, so use `keep_alive` for anything big or passed by pointer, such as an array or a slice.

## Keep setup and I/O out of the timed part

Build the input before the `step` loop when the routine doesn't change it. When it does, such as sorting in place or popping from a queue, use `iter_batched`: it builds a batch of inputs with the clock paused, then runs the routine over the whole batch in one timed window.

`pause` and `resume` work too, but each `resume` starts a new timed window, and every window costs one read of the clock, which obench measures at startup and subtracts. On an M2 that overhead came out between 14 and 43 ns from one run to the next. Pausing around work smaller than that leaves a result that is mostly the clock, or one where samples drop below the overhead and count as 0. obench marks those rows `[overhead-dominated]` or `[clamped: N/M samples]`. Time a bigger piece of work, or move the setup out of the loop.

The same goes for I/O. To compare two formatting routines, write into a `strings.Builder` or a buffer and benchmark that. Writing to a file or the terminal adds the operating system's cost and its noise to every sample.

## Count allocations as well as time

Allocations are often the biggest cost in a hot path, and the count is exact where time never is. obench counts allocator calls that obtain memory and their bytes per operation, for the heap and the temp allocator separately. `// @zero_alloc` above a benchmark makes it fail when the measured loop allocates on the heap. In CI, `--fail-on-alloc-regression` fails a run that allocates more than its baseline, a check that stays reliable on a noisy shared runner.

## Read the whole distribution

`fastest` is what the code can do when nothing gets in the way, `median(p50)` is the typical sample, and `p99` shows the slow tail. A wide gap between them, or a sparkline with two humps, means the samples aren't telling one story, usually because something else ran or the CPU changed speed. The notes column says when a result is close to the timer's resolution or dominated by its overhead, and the `x faster` and `x slower` labels only appear when the difference is statistically significant and above 3%.

## Compare runs, not numbers from memory

Save a run with `--save-baseline main.json` and check the next one with `--baseline main.json`, or compare two saved reports with `obench compare`. A baseline only means something against a run from the same machine and the same build settings, so `--fail-on-regression` fails against one built with another `-o` mode, OS or architecture. `--threshold` sets how big a change of the median has to be before it counts, 2% by default.
