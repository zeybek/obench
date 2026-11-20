# Run benchmarks inside `odin test`

A package of tests can run benchmarks too, so `odin test` checks them along with everything else. `run_test` runs a suite from a `@(test)` procedure, logs the report, and fails the test on any problem `suite_run` would report: a benchmark that misused the `Bencher`, a failed `@zero_alloc` check, a regression under `fail_on_regression` or `fail_on_alloc_regression`, or a report file that couldn't be read or written. Each problem is its own failure that names the benchmark and the reason.

```odin
package my_benchmarks

import "core:testing"
import obench "libs/obench"

@(test)
sorting :: proc(t: ^testing.T) {
	s := obench.suite_create("sorting")
	defer obench.suite_destroy(&s)
	obench.bench(&s, "slice_sort", slice_sort_bench)
	obench.run_test(t, &s)
}
```

Run it with an optimized build, since benchmarks of a debug build mean little and the report warns about it:

```sh
odin test my_benchmarks -o:speed
```

Inside `odin test`, `suite_create` doesn't read command-line flags, because those belong to the test runner, but it does read the `OBENCH_*` environment variables, so `OBENCH_SAMPLES=10 odin test my_benchmarks -o:speed` takes fewer samples.

[`examples/core_style`](../../examples/core_style/prefix_length_test.odin) is a full example. It measures `core:strings.prefix_length`, the same thing as Odin's own `tests/benchmark/strings`, checks first that both implementations agree, and gives each of them a group over six sizes with `@zero_alloc`:

```sh
odin test examples/core_style -o:speed
```

On an Apple M2, for 1024 bytes of ASCII, Odin's own benchmark timed 2500 calls at 44.5 µs, or 17.8 ns per call. The obench example reported 19.25 ns fastest, 19.62 ns median, and 34.54 ns p99 for the same call, with a Big-O fit across the six sizes and a check that the call doesn't allocate.

Like `odin build`, the CLI leaves out `#+test` files, which only `odin test` builds, so run benchmarks written as tests with `odin test` and packages of `bench_*` procedures with the CLI.
