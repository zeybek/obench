# How obench decides that something changed

## Samples

A benchmark runs in samples. Each sample is one batch of iterations, timed as a whole and divided by the batch size, so the time per operation doesn't drown in the cost of reading the clock. Before sampling, obench warms the benchmark up for 40 ms and calibrates the batch until one sample takes at least 1 ms. Then it takes 50 samples, unless the time budget of 1.2 s runs out first, in which case it keeps at least 10. `-n`, `-w`, `--min-sample-time`, `--max-time`, and `--batch-size` change these, and so do the `OBENCH_*` variables.

The table shows the fastest sample, the median, and p99. Compare medians: unlike the mean, a few slow samples hardly move it. The JSON report also has the mean, the standard deviation, the MAD, p95, and every sample (`samples_ns`).

## Samples that follow each other aren't independent

One slow stretch of the machine, from a frequency change or another process, covers several samples in a row. obench measures that as the lag-1 autocorrelation of the samples in the order they ran (`autocorrelation` in the report) and counts how many independent samples they're worth, `n(1 - r)/(1 + r)` for a positive correlation r (`effective_samples`). At r = 0.4, 50 samples are worth about 21. `ci95_ns`, the 95% confidence interval of the mean, uses that smaller count, so it isn't narrower than the data allows.

Two more checks look at the shape of the samples. `[drifts +8%]` means the times moved steadily over the run, by that much from the first sample to the last: a Theil-Sen slope with a Mann-Kendall test at the 1% level, flagged from a 5% change (`sample_trend`). `[2 modes]` means the samples fell into two groups, found as peaks of a kernel density estimate (`count_modes`). Both usually mean the machine changed speed during the run.

## Deciding that a benchmark changed

Comparing a run with a baseline, obench estimates the change as the Hodges-Lehmann shift: the median of the ratios between every sample of one run and every sample of the other. Its 95% confidence interval comes from the Mann-Whitney U test, exact up to 20 samples a side and widened for correlated samples above that (`hodges_lehmann_shift`). Both work on ranks, so a few very slow samples in either run can't hide a shift of the rest.

A change counts as a regression only when its whole interval lies above `--threshold` (2% by default), and as an improvement only when it lies below minus the threshold. A shift that might still be smaller than the threshold isn't flagged, however small its p-value is. `compare` prints the interval and the p-value of every benchmark, and under the summary how many flags noise between samples could cause on its own: at most 5% of the benchmarks. Against a report from before format version 3, which has no samples, Welch's t-test on the means decides instead.

The `x faster` labels in a run compare each benchmark with the first one of its group in the same way, with a threshold of 3%.

## Processes differ more than samples

All the samples of a run come from one process. Two processes running the same code differ by more than the samples inside one, because the memory layout, the environment, and the state of the machine change between them, so an interval built from the samples of one process is too narrow for a comparison between processes. On an M2, four runs of `examples/lookup`, compared pairwise, flagged 48 of 144 benchmark comparisons although nothing changed.

`--count 5` runs every package in five processes, each with a random amount of padding in its environment and a random offset of its stack, and keeps the median of each process (`process_medians_ns`, combined by `combine_runs`). When both sides of a comparison come from at least two processes, the test compares the process medians instead of the samples. The same four runs with `--count 5` flagged none of the 144 comparisons. `obench ab` goes one step further and runs the two sides alternately on one machine, so whatever drifts during the job affects both alike. With few processes the interval is wide: 6 rounds of `ab` is a good minimum.

This repository's weekly A/A job checks the result: three reports of the examples from `--count 5`, compared pairwise, may flag at most 5% of their comparisons.

## Complexity fits

For a group with three or more `@params` sizes, obench fits `T(N) = a + c * f(N)` for each class from O(1) to O(N³), so a fixed cost per call doesn't bend the curve. It reports a growing class only when it fits significantly better than a constant, by an F-test at the 5% level. With three sizes that test is strict, so a noisy curve over few sizes can come out as O(1): use four or more sizes when the class matters. For O(1), the reported R² is `1 - NRMSE²`, how flat the times are, since a constant explains no variance.
