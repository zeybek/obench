# Your first benchmark

This tutorial measures two ways to fill a dynamic array, letting it grow and reserving its capacity first, and reads what obench prints. It needs Odin `dev-2026-10` or newer.

## 1. Add the library

Copy the `obench` folder of this repository into your project as `libs/obench`. Each [release](https://github.com/zeybek/obench/releases) has it as `obench-<tag>-library.tar.gz` and `.zip`. The project then looks like this:

```text
my_project/
├── libs/
│   └── obench/      the library: obench/*.odin and LICENSE
└── bench/           your benchmarks
```

[Add obench to a project](how-to/vendoring.md) shows the other ways, such as a git subtree pinned to a release.

## 2. Write the benchmarks

Create `bench/append_bench.odin`:

```odin
package append_bench

import obench "../libs/obench"

// @params(16, 256, 4096)
bench_append__grow :: proc(b: ^obench.Bencher) {
	n := obench.param(b)
	for obench.step(b) {
		values: [dynamic]int
		for i in 0 ..< n {
			append(&values, i)
		}
		obench.keep_alive(&values)
		delete(values)
	}
}

// @params(16, 256, 4096)
bench_append__reserve :: proc(b: ^obench.Bencher) {
	n := obench.param(b)
	for obench.step(b) {
		values := make([dynamic]int, 0, n)
		for i in 0 ..< n {
			append(&values, i)
		}
		obench.keep_alive(&values)
		delete(values)
	}
}
```

A benchmark is a procedure named `bench_<name>` that takes a `^obench.Bencher`. Only the body of the `for obench.step(b)` loop is timed and has its allocations counted, so setup before the loop costs nothing. The part before `__` is the group: `grow` and `reserve` are both in `append`, so the table compares them. `@params(16, 256, 4096)` runs the group once per value, which `obench.param(b)` returns. `keep_alive` tells the compiler that something reads the array, so it can't delete the loop.

The package needs no `main`. The CLI finds the procedures, writes a small runner for them into a temporary directory, and deletes it afterwards.

## 3. Build the CLI and run it

From a clone of this repository (on Windows, use `-out:bin/obench.exe`):

```sh
mkdir -p bin
odin build cmd/obench -out:bin/obench -o:speed
```

Or take a prebuilt CLI from a release. It still needs `odin` on `PATH`, since it builds your benchmarks with it. Then run it in your project:

```sh
cd my_project
obench .
```

It searches the directory and its subdirectories, finds `bench`, and skips `libs/obench`, since that's a copy of obench itself. On an Apple M2 it printed:

```text
obench: append_bench (darwin/arm64, -o:Speed, timer overhead 14.8 ns, resolution 41.0 ns, empty loop 778.1 ps)
─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
benchmark         │   fastest │ median(p50) │       p99 │   allocs / bytes │ distribution & notes
─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
append
 ├─ grow[16]      │  78.31 ns │    78.74 ns │ 267.75 ns │      2.0 / 128 B │ █▁  ▁  ▁
 ├─ reserve[16]   │  29.48 ns │    30.03 ns │  32.76 ns │      1.0 / 128 B │ █▂▁▅▁▁ ▁ 2.62x faster [drifts -6%] [2 modes]
 ├─ grow[256]     │ 613.37 ns │   618.18 ns │ 636.57 ns │   6.0 / 2.00 KiB │ ▂█▂▁▂ ▁▁ [2 modes]
 ├─ reserve[256]  │ 219.22 ns │   228.39 ns │ 250.16 ns │   1.0 / 2.00 KiB │ █▁█▁▁▁ ▁ 2.71x faster
 ├─ grow[4096]    │   5.89 us │     5.93 us │   6.52 us │ 10.0 / 32.00 KiB │ █▂ ▁▁▁ ▁
 ╰─ reserve[4096] │   3.32 us │     3.41 us │   3.61 us │  1.0 / 32.00 KiB │ ▆▁█▄▁▁ ▁ 1.74x faster
   ∷ complexity grow    → O(N) (R²=0.999, NRMSE=3.7%)
   ∷ complexity reserve → O(N) (R²=1.000, NRMSE=0.0%)
─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
PASS: 6 benchmark(s) completed │ geomean: 434.80 ns
```

Your numbers will differ, but the shape should be the same.

## 4. Read the table

The header names the suite, the platform, and the optimization mode, and then what obench measured about the clock: what one timed window costs, which it subtracts from every sample, the smallest step of the clock, and how long an empty `step` loop takes per iteration. [The clock, its overhead, and the other counters](explanation/timer.md) explains them.

`fastest`, `median(p50)`, and `p99` are per operation. Each sample is one batch of iterations, calibrated to take at least 1 ms, and obench takes 50 of them per benchmark after a warmup, unless the time budget runs out first. The median is the number to look at. p99 shows the slow tail, like the 267.75 ns of `grow[16]`.

`allocs / bytes` counts allocator calls per operation, resizes included. Reserving allocates once, while growing to 4096 items allocates once and resizes 9 times. These counts are exact, so they don't vary between runs. [How allocations are counted](explanation/allocations.md) says how.

The last column starts with a histogram of the samples between the fastest and p99. `2.62x faster` compares a benchmark with the first one of its group for the same parameter, and only appears when the difference clears a significance test. `[drifts -6%]` means the times moved steadily during the run, and `[2 modes]` that the samples fell into two groups. Both usually mean the machine changed speed while it ran. [How obench decides that something changed](explanation/statistics.md) explains them.

The `complexity` lines fit a Big-O class to each benchmark's times across the `@params` sizes. Both are O(N) here. A line like `O(N log N) or O(N)` means both classes fit the sizes you gave, and more sizes would tell them apart.

## 5. Compare with the next change

Save this run as a baseline, change the code, and run again against it:

```sh
obench . --save-baseline main.json
# ...change the code...
obench . --baseline main.json
```

Every row then shows its change against the baseline in its notes, and `--fail-on-regression` turns a significant slowdown into exit status 1. One run on one machine is noisy, though. [Gate a pull request on performance](how-to/ci-gate.md) shows how to make the comparison hold up, with `--count` and `obench ab`.

## Next

- `obench help` lists every option.
- [Benchmark Odin code well](how-to-benchmark.md) covers the mistakes that make a benchmark measure the wrong thing.
- The [package documentation](https://zeybek.github.io/obench/obench/) covers destructive benchmarks (`iter_batched`), multi-threaded ones (`run_parallel`), custom metrics, and running benchmarks from your own `main`.
