# obench documentation

## Tutorial

[Your first benchmark](tutorial.md) goes from copying the library into a project to reading the table it prints.

## How-to guides

- [Gate a pull request on performance](how-to/ci-gate.md), with baselines, `--count`, `obench ab`, the exit statuses, and the exact gates on allocations and instructions
- [Run benchmarks inside `odin test`](how-to/odin-test.md)
- [Add obench to a project](how-to/vendoring.md) as a copy, a git subtree or submodule pinned to a tag, or an `ols.json` collection
- [Benchmark Odin code well](how-to-benchmark.md): optimized builds, warmup, keeping the compiler from deleting the work, and keeping setup out of the timed part

## Explanations

- [How obench decides that something changed](explanation/statistics.md)
- [How allocations are counted](explanation/allocations.md)
- [The clock, its overhead, and the other counters](explanation/timer.md)

## Reference

The [package documentation](https://zeybek.github.io/obench/obench/) has every procedure, type, and option, the environment variables, and the known limits. `obench help` lists the CLI's options, and [`schema/`](../schema/) holds the JSON Schema of the report. [STABILITY.md](../STABILITY.md) says what counts as the public API.

## Migration notes

[Migration notes](migration.md) say what to change for every breaking release.
