# obench

[![CI](https://github.com/zeybek/obench/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/zeybek/obench/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/zeybek/obench?include_prereleases&sort=semver)](https://github.com/zeybek/obench/releases)
[![Docs](https://img.shields.io/badge/docs-API%20reference-blue)](https://zeybek.github.io/obench/obench/)
[![Odin](https://img.shields.io/badge/Odin-dev--2026--10%2B-1e5fa8)](https://odin-lang.org/)
[![Dependencies](https://img.shields.io/badge/dependencies-base%20%2B%20core-brightgreen)](https://github.com/zeybek/obench/tree/main/obench)
[![License](https://img.shields.io/badge/license-BSD--3--Clause-blue)](https://github.com/zeybek/obench/blob/main/LICENSE)

Allocation-aware micro-benchmarking for [Odin](https://odin-lang.org/). It measures time and heap and temp allocations per operation, and compares runs against a saved baseline. It uses only `base:` and `core:` packages.

Status: before 1.0. The API and the JSON report layout can still change, and the [release notes](https://github.com/zeybek/obench/releases) list every breaking change.

## Guide

The [package documentation](https://zeybek.github.io/obench/obench/) covers the annotations, destructive and multi-threaded benchmarks, running from your own `main` or inside `odin test`, reading the report, configuration, and the known limits. `obench help` lists the CLI options.

## Getting Started

obench needs Odin `dev-2026-10` or newer. CI tests it on Linux (x86 and ARM), macOS (ARM and Intel), and Windows against the latest Odin release and the nightly build.

1. Copy the `obench` folder of this repository into your project, for example as `libs/obench`. Each [release](https://github.com/zeybek/obench/releases) has it as `obench-<tag>-library.tar.gz` and `.zip`, together with the license.

2. Create a benchmark file such as `bench/append_bench.odin`. A benchmark is a procedure named `bench_<name>` that takes a `^obench.Bencher`, and only the body of the `step` loop is timed and counted:

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

3. Build the CLI from a clone of this repository (on Windows, use `-out:bin/obench.exe`), or take a prebuilt one from a release (it still needs `odin` on `PATH`), and run it on your project:

    ```sh
    odin build cmd/obench -out:bin/obench -o:speed
    ./bin/obench path/to/project
    ```

    On an Apple M2:

    ```text
    obench: append_bench (darwin/arm64, -o:Speed, timer overhead 28.5 ns, resolution 41.0 ns)
    ──────────────────────────────────────────────────────────────────────────────────────────────────
    benchmark         │   fastest │ median(p50) │       p99 │   allocs / bytes │ distribution & notes
    ──────────────────────────────────────────────────────────────────────────────────────────────────
    append
     ├─ grow[16]      │  77.41 ns │    78.29 ns │  82.36 ns │      2.0 / 128 B │ █▆▁▂ ▂▂▁
     ├─ reserve[16]   │  35.49 ns │    38.04 ns │  43.22 ns │      1.0 / 128 B │ ▅█▅▄▄▃▁▁ 2.06x faster
     ├─ grow[256]     │ 540.42 ns │   545.34 ns │ 579.68 ns │   6.0 / 2.00 KiB │ █▂▂▁▁  ▁
     ├─ reserve[256]  │ 232.38 ns │   239.52 ns │ 305.09 ns │   1.0 / 2.00 KiB │ █▃▁▁   ▁ 2.28x faster
     ├─ grow[4096]    │   4.68 us │     4.80 us │   5.42 us │ 10.0 / 32.00 KiB │ ██▂▂▁▁▁▁
     ╰─ reserve[4096] │   3.32 us │     3.39 us │   3.54 us │  1.0 / 32.00 KiB │ █▂▄▃▂▁▁▂ 1.42x faster
       ∷ complexity grow    → O(N) (R²=0.999, NRMSE=4.4%)
       ∷ complexity reserve → O(N) (R²=1.000, NRMSE=0.2%)
    ──────────────────────────────────────────────────────────────────────────────────────────────────
    PASS: 6 benchmark(s) completed │ geomean: 430.06 ns
    ```

    `allocs / bytes` counts allocator calls that obtain memory, so the resizes of the growing array show up next to the single allocation of the reserved one.

## Checking benchmarks in CI

Save a baseline on one branch and compare another branch against it. `--fail-on-regression` exits with status 1 when a benchmark got significantly slower:

```sh
obench --save-baseline main.json
# ...switch branches...
obench --baseline main.json --fail-on-regression
```

A change counts as a regression when the Mann-Whitney U test on the samples of both runs finds a difference at the 5% level and the median moved by more than `--threshold` percent (2% by default). Shared CI runners are noisy, so a real change can still drown in their noise. For a gate, raise the sample count with `-n` or run it on a dedicated machine.

Benchmarks can also run inside `odin test`: `run_test` runs a suite from a `@(test)` procedure and fails the test on a misused benchmark, a failed `@zero_alloc` check, or a regression.

## Examples

Example benchmarks are in [examples](https://github.com/zeybek/obench/tree/main/examples). Run them locally with:

```sh
git clone https://github.com/zeybek/obench
cd obench
make bench
```

[examples/core_style](https://github.com/zeybek/obench/blob/main/examples/core_style/prefix_length_test.odin) runs inside `odin test` and measures `core:strings.prefix_length`, the same thing as Odin's own `tests/benchmark/strings`.

## License

BSD 3-Clause, see [LICENSE](https://github.com/zeybek/obench/blob/main/LICENSE).
