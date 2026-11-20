# How allocations are counted

obench counts allocations without a global hook. While a benchmark runs, it swaps `context.allocator` and `context.temp_allocator` for counting allocators that pass every call on to the real ones. Only the body of the `step` loop is counted: setup before the loop, and work between `pause` and `resume`, isn't. That's also why the counts are exact and the same on every run.

## What counts

`allocs / bytes` counts allocator calls that obtain memory, per operation, and resizes are such calls. Building a 64-item dynamic array from a capacity of 16 shows `3.0 / 512 B`: one allocation and two resizes. A benchmark that only uses the temp allocator shows `0 (tmp 3.0/512 B)`. The JSON report has the heap and temp counts and bytes separately, the resizes, and the most memory the benchmark held at once (`peak_heap_bytes`).

## Counting outside the timed samples

The counting allocators cost time on every call, so obench doesn't use them in the timed samples. After the samples, it runs one more batch, untimed, with the counters on, and reports its counts. The times of a benchmark that allocates then don't include any counting.

`--timed-allocs` (or `OBENCH_UNTIMED_ALLOCS=0`) counts in every timed sample instead, as obench did before 0.3. Benchmarks that allocate then also pay for the counting: in `examples/allocators` on an M2, `heap` took 14% longer and `temp_allocator` 19% longer. A baseline saved one way can't be compared with a run counted the other way when it has a benchmark that allocates, and a regression gate against it ends with exit status 3. A `Config` literal that leaves out `untimed_alloc_check = true` counts in every timed sample, since its zero value is false. `default_config` sets it to true.

## `@zero_alloc`

A benchmark marked `@zero_alloc`, or run with `--zero-alloc`, fails if its loop allocates on the heap. Its heap is checked in every timed sample, which costs nothing until it allocates, and the report prints the file, line, and procedure of the first allocation. `expect_zero_allocs(b)` does the same from inside the procedure.

## Gating on allocations

Since the counts are exact, `--fail-on-alloc-regression` makes a gate that holds on a noisy machine. It fails when a benchmark allocates more per operation than in the baseline, heap or temp, count or bytes, with no threshold and no test, and the table marks the benchmark `[allocs grew]`.
