package obench

import "base:intrinsics"
import "core:math"
import "core:slice"

// Number of bins in `Stats.histogram` (one sparkline character each).
HISTOGRAM_BINS :: 8
// Maximum number of distinct `report_metric` units kept per benchmark.
MAX_CUSTOM_METRICS :: 4

/*
User-defined domain metric reported via `report_metric(b, value, unit)`
(modeled after Go's `testing.B.ReportMetric` and Google Benchmark's `Counter`).
*/
Custom_Metric :: struct {
	unit:  string `json:"unit"`,
	value: f64 `json:"value"`,
}

/*
Statistical summary for a completed benchmark entry.
*/
Stats :: struct {
	samples:              int,
	batch_size:           int,
	total_iters:          u64,

	// Wall-clock time per operation (nanoseconds)
	min_ns:               f64,
	max_ns:               f64,
	mean_ns:              f64,
	std_dev_ns:           f64,
	ci95_ns:              f64, // Half-width of the mean's 95% confidence interval (Student's t * SE)
	cv_pct:               f64,
	p25_ns:               f64,
	p50_ns:               f64, // Median
	p75_ns:               f64,
	p95_ns:               f64,
	p99_ns:               f64,
	iqr_ns:               f64,
	mad_ns:               f64, // Median Absolute Deviation

	// Outliers (Tukey 1.5 * IQR fence)
	low_outliers:         int,
	high_outliers:        int,
	histogram:            [HISTOGRAM_BINS]u8,

	// Hardware CPU cycles per operation
	min_cycles:           f64,
	max_cycles:           f64,
	mean_cycles:          f64,
	median_cycles:        f64,

	// Throughput (computed from median p50_ns)
	bytes_per_op:         u64,
	items_per_op:         u64,
	mb_per_sec:           f64, // Mebibytes (2^20 bytes) per second
	items_per_sec:        f64,

	// Memory allocation metrics per operation. `allocs_per_op` counts allocator calls that
	// obtain memory: new allocations plus resizes of existing allocations (see
	// `resizes_per_op` for the resize share).
	allocs_per_op:        f64,
	resizes_per_op:       f64,
	alloc_bytes_per_op:   f64,
	temp_allocs_per_op:   f64,
	temp_bytes_per_op:    f64,
	peak_heap_bytes:      i64,

	// Custom user metrics
	custom_metrics:       [MAX_CUSTOM_METRICS]Custom_Metric,
	custom_metrics_count: int,

	// Time per operation of every sample in the order taken, used by `compare_baseline`.
	// `compute_stats` points it at its `ns_per_op` argument. The suite keeps its own copy in
	// each `Result`, and `load_baseline_file` allocates one per entry. Empty for reports
	// written before format version 3.
	samples_ns:           []f64,
}

/*
Comparison against a saved baseline measurement.
*/
Baseline_Diff :: struct {
	has_baseline:     bool,
	delta_median_pct: f64,
	delta_mean_pct:   f64,
	delta_allocs_pct: f64,
	delta_bytes_pct:  f64,
	welch_t:          f64,
	welch_df:         f64, // Welch-Satterthwaite degrees of freedom
	rank_test:        bool, // Significance came from the Mann-Whitney U test (both sides had samples)
	p_value:          f64, // Two-sided p-value of the Mann-Whitney U test when `rank_test` is set
	is_significant:   bool,
	is_regression:    bool,
	is_improvement:   bool,
}

/*
Aggregate summary across an entire `Suite` or comparison run (modeled after Go's `benchstat`).
*/
Suite_Summary :: struct {
	total_benchmarks:  int,
	geomean_ns:        f64,
	has_baseline_diff: bool,
	geomean_delta_pct: f64,
	improvements:      int,
	regressions:       int,
	unchanged:         int,
}

/*
Computes full parametric and non-parametric statistics from sample slices.
`ns_per_op` and `cycles_per_op` contain one entry per sample (already divided by `batch_size`).
The returned `samples_ns` refers to `ns_per_op`, so clone it if the stats outlive the slice.
*/
@(require_results)
compute_stats :: proc(
	ns_per_op: []f64,
	cycles_per_op: []f64,
	batch_size: int,
	total_iters: u64,
	bytes_per_op: u64,
	items_per_op: u64,
	heap_counter: ^Counting_Allocator,
	temp_counter: ^Counting_Allocator,
	custom_metrics: []Custom_Metric = nil,
	allocator := context.allocator,
) -> Stats {
	n := len(ns_per_op)
	if n == 0 {
		return Stats{}
	}

	sorted_ns := slice.clone(ns_per_op, allocator)
	defer delete(sorted_ns, allocator)
	slice.sort(sorted_ns)

	sorted_cyc := slice.clone(cycles_per_op, allocator)
	defer delete(sorted_cyc, allocator)
	slice.sort(sorted_cyc)

	min_ns := sorted_ns[0]
	max_ns := sorted_ns[n - 1]
	p25_ns := percentile_sorted(sorted_ns, 0.25)
	p50_ns := percentile_sorted(sorted_ns, 0.50)
	p75_ns := percentile_sorted(sorted_ns, 0.75)
	p95_ns := percentile_sorted(sorted_ns, 0.95)
	p99_ns := percentile_sorted(sorted_ns, 0.99)
	iqr_ns := p75_ns - p25_ns

	// Mean, sample standard deviation, and 95% confidence interval half-width
	sum_ns: f64 = 0
	for v in sorted_ns {
		sum_ns += v
	}
	mean_ns := sum_ns / f64(n)

	var_sum: f64 = 0
	for v in sorted_ns {
		diff := v - mean_ns
		var_sum += diff * diff
	}
	std_dev_ns: f64 = 0
	ci95_ns: f64 = 0
	if n > 1 {
		std_dev_ns = math.sqrt(var_sum / f64(n - 1))
		ci95_ns = t_critical_975(f64(n - 1)) * (std_dev_ns / math.sqrt(f64(n)))
	}
	cv_pct: f64 = 0
	if mean_ns > 0 {
		cv_pct = (std_dev_ns / mean_ns) * 100.0
	}

	// Median Absolute Deviation (MAD)
	abs_devs := make([]f64, n, allocator)
	defer delete(abs_devs, allocator)
	for v, i in sorted_ns {
		abs_devs[i] = abs(v - p50_ns)
	}
	slice.sort(abs_devs)
	mad_ns := percentile_sorted(abs_devs, 0.50)

	// Tukey 1.5 * IQR outliers
	low_fence := p25_ns - 1.5 * iqr_ns
	high_fence := p75_ns + 1.5 * iqr_ns
	low_outliers := 0
	high_outliers := 0
	for v in sorted_ns {
		if v < low_fence {
			low_outliers += 1
		} else if v > high_fence {
			high_outliers += 1
		}
	}

	// 8-bin histogram for Unicode sparklines
	hist: [HISTOGRAM_BINS]u8
	lo := min_ns
	hi := p99_ns > min_ns ? p99_ns : max_ns
	span := hi - lo
	if span > 0 {
		counts: [HISTOGRAM_BINS]int
		max_bin_count := 0
		for v in sorted_ns {
			norm := (v - lo) / span
			idx := int(norm * f64(HISTOGRAM_BINS))
			if idx < 0 {
				idx = 0
			} else if idx >= HISTOGRAM_BINS {
				idx = HISTOGRAM_BINS - 1
			}
			counts[idx] += 1
			if counts[idx] > max_bin_count {
				max_bin_count = counts[idx]
			}
		}
		if max_bin_count > 0 {
			for c, i in counts {
				if c == 0 {
					hist[i] = 0
				} else {
					scaled := int(math.round((f64(c) / f64(max_bin_count)) * 7.0))
					if scaled < 1 {
						scaled = 1
					}
					hist[i] = u8(scaled)
				}
			}
		}
	} else {
		hist[HISTOGRAM_BINS / 2] = 7
	}

	// Cycles stats
	min_cyc := sorted_cyc[0]
	max_cyc := sorted_cyc[n - 1]
	med_cyc := percentile_sorted(sorted_cyc, 0.50)
	sum_cyc: f64 = 0
	for c in sorted_cyc {
		sum_cyc += c
	}
	mean_cyc := sum_cyc / f64(n)

	// Throughput (based on median duration)
	mb_per_sec: f64 = 0
	items_per_sec: f64 = 0
	if p50_ns > 0 {
		ops_per_sec := 1_000_000_000.0 / p50_ns
		if bytes_per_op > 0 {
			mb_per_sec = (f64(bytes_per_op) * ops_per_sec) / (1024.0 * 1024.0)
		}
		if items_per_op > 0 {
			items_per_sec = f64(items_per_op) * ops_per_sec
		}
	}

	// Allocation stats (using atomic loads)
	allocs_per_op: f64 = 0
	resizes_per_op: f64 = 0
	alloc_bytes_per_op: f64 = 0
	temp_allocs_per_op: f64 = 0
	temp_bytes_per_op: f64 = 0
	peak_heap: i64 = 0

	if total_iters > 0 {
		iters_f := f64(total_iters)
		if heap_counter != nil {
			ac := intrinsics.atomic_load_explicit(&heap_counter.alloc_count, .Relaxed)
			rc := intrinsics.atomic_load_explicit(&heap_counter.resize_count, .Relaxed)
			ab := intrinsics.atomic_load_explicit(&heap_counter.bytes_allocated, .Relaxed)
			pk := intrinsics.atomic_load_explicit(&heap_counter.peak_bytes, .Relaxed)
			allocs_per_op = f64(ac + rc) / iters_f
			resizes_per_op = f64(rc) / iters_f
			alloc_bytes_per_op = f64(ab) / iters_f
			peak_heap = pk
		}
		if temp_counter != nil {
			tc := intrinsics.atomic_load_explicit(&temp_counter.alloc_count, .Relaxed)
			tr := intrinsics.atomic_load_explicit(&temp_counter.resize_count, .Relaxed)
			tb := intrinsics.atomic_load_explicit(&temp_counter.bytes_allocated, .Relaxed)
			temp_allocs_per_op = f64(tc + tr) / iters_f
			temp_bytes_per_op = f64(tb) / iters_f
		}
	}

	st := Stats {
		samples            = n,
		batch_size         = batch_size,
		total_iters        = total_iters,
		min_ns             = min_ns,
		max_ns             = max_ns,
		mean_ns            = mean_ns,
		std_dev_ns         = std_dev_ns,
		ci95_ns            = ci95_ns,
		cv_pct             = cv_pct,
		p25_ns             = p25_ns,
		p50_ns             = p50_ns,
		p75_ns             = p75_ns,
		p95_ns             = p95_ns,
		p99_ns             = p99_ns,
		iqr_ns             = iqr_ns,
		mad_ns             = mad_ns,
		low_outliers       = low_outliers,
		high_outliers      = high_outliers,
		histogram          = hist,
		min_cycles         = min_cyc,
		max_cycles         = max_cyc,
		mean_cycles        = mean_cyc,
		median_cycles      = med_cyc,
		bytes_per_op       = bytes_per_op,
		items_per_op       = items_per_op,
		mb_per_sec         = mb_per_sec,
		items_per_sec      = items_per_sec,
		allocs_per_op      = allocs_per_op,
		resizes_per_op     = resizes_per_op,
		alloc_bytes_per_op = alloc_bytes_per_op,
		temp_allocs_per_op = temp_allocs_per_op,
		temp_bytes_per_op  = temp_bytes_per_op,
		peak_heap_bytes    = peak_heap,
		samples_ns         = ns_per_op,
	}

	cm_count := min(len(custom_metrics), MAX_CUSTOM_METRICS)
	st.custom_metrics_count = cm_count
	for i in 0 ..< cm_count {
		st.custom_metrics[i] = custom_metrics[i]
	}

	return st
}

/*
Linear interpolation percentile on an already-sorted slice (`p` in `0.0 ..= 1.0`).
*/
@(require_results)
percentile_sorted :: proc "contextless" (sorted: []f64, p: f64) -> f64 {
	n := len(sorted)
	if n == 0 {
		return 0
	}
	if n == 1 || p <= 0.0 {
		return sorted[0]
	}
	if p >= 1.0 {
		return sorted[n - 1]
	}
	pos := p * f64(n - 1)
	lo := int(pos)
	hi := lo + 1
	if hi >= n {
		return sorted[n - 1]
	}
	frac := pos - f64(lo)
	return sorted[lo] + frac * (sorted[hi] - sorted[lo])
}

/*
The 97.5% quantile of Student's t distribution (the two-sided critical value for a 5%
significance level) for `df` degrees of freedom, which need not be a whole number.

Below 1000 degrees of freedom it solves $I_y(1/2, df/2) = 0.95$ for $y = t^2 / (df + t^2)$
with the regularized incomplete beta function. From 1000 on, the Cornish-Fisher expansion
around the normal quantile is closer than 1e-14. `tests/scipy_reference_test.odin` checks
the result against scipy to 1e-9. A `df` below 1 counts as 1, and an infinite or invalid
`df` gives the normal quantile.
*/
@(require_results)
t_critical_975 :: proc "contextless" (df: f64) -> f64 {
	Z :: 1.959963984540054
	if df <= 0 || math.is_inf(df, 0) || math.is_nan(df) {
		return Z
	}
	d := max(df, 1.0)
	if d < 1000 {
		// I_y(1/2, df/2) grows with y, so bisect until the interval stops shrinking.
		lo, hi: f64 = 0, 1
		for _ in 0 ..< 200 {
			mid := (lo + hi) / 2
			if mid <= lo || mid >= hi {
				break
			}
			if _incomplete_beta(0.5, d / 2, mid) < 0.95 {
				lo = mid
			} else {
				hi = mid
			}
		}
		y := (lo + hi) / 2
		return math.sqrt(d * y / (1 - y))
	}
	z3 := Z * Z * Z
	z5 := z3 * Z * Z
	z7 := z5 * Z * Z
	z9 := z7 * Z * Z
	g1 := (z3 + Z) / 4.0
	g2 := (5.0 * z5 + 16.0 * z3 + 3.0 * Z) / 96.0
	g3 := (3.0 * z7 + 19.0 * z5 + 17.0 * z3 - 15.0 * Z) / 384.0
	g4 := (79.0 * z9 + 776.0 * z7 + 1482.0 * z5 - 1920.0 * z3 - 945.0 * Z) / 92160.0
	return Z + g1 / d + g2 / (d * d) + g3 / (d * d * d) + g4 / (d * d * d * d)
}

// Regularized incomplete beta function $I_x(a, b)$ for `a, b > 0`.
@(private = "file")
_incomplete_beta :: proc "contextless" (a, b, x: f64) -> f64 {
	if x <= 0 {
		return 0
	}
	if x >= 1 {
		return 1
	}
	lab, _ := math.lgamma(a + b)
	la, _ := math.lgamma(a)
	lb, _ := math.lgamma(b)
	front := math.exp(lab - la - lb + a * math.ln(x) + b * math.log1p(-x))
	// The continued fraction converges fast on this side of the mean; use symmetry otherwise.
	if x < (a + 1) / (a + b + 2) {
		return front * _beta_fraction(a, b, x) / a
	}
	return 1 - front * _beta_fraction(b, a, 1 - x) / b
}

// Continued fraction of the incomplete beta function, by the modified Lentz method.
@(private = "file")
_beta_fraction :: proc "contextless" (a, b, x: f64) -> f64 {
	TINY :: 1e-300
	EPS :: 1e-15
	c: f64 = 1
	d := 1 - (a + b) * x / (a + 1)
	d = 1 / (abs(d) < TINY ? TINY : d)
	h := d
	for i in 1 ..= 300 {
		m := f64(i)
		num := m * (b - m) * x / ((a + 2 * m - 1) * (a + 2 * m))
		d = 1 + num * d
		d = 1 / (abs(d) < TINY ? TINY : d)
		c = 1 + num / c
		c = abs(c) < TINY ? TINY : c
		h *= d * c

		num = -(a + m) * (a + b + m) * x / ((a + 2 * m) * (a + 2 * m + 1))
		d = 1 + num * d
		d = 1 / (abs(d) < TINY ? TINY : d)
		c = 1 + num / c
		c = abs(c) < TINY ? TINY : c
		delta := d * c
		h *= delta
		if abs(delta - 1) < EPS {
			break
		}
	}
	return h
}

/*
Welch's t statistic and Welch-Satterthwaite degrees of freedom for two independent samples
described by their mean, sample standard deviation, and size.
*/
@(require_results)
welch_test :: proc "contextless" (
	mean_a, sd_a: f64,
	n_a: int,
	mean_b, sd_b: f64,
	n_b: int,
) -> (
	t: f64,
	df: f64,
) {
	if n_a < 2 || n_b < 2 {
		return 0, 0
	}
	va := (sd_a * sd_a) / f64(n_a)
	vb := (sd_b * sd_b) / f64(n_b)
	se_sq := va + vb
	if se_sq <= 0 {
		if mean_a == mean_b {
			return 0, f64(n_a + n_b - 2)
		}
		// Zero variance on both sides but different means: treat as a certain difference.
		return mean_a > mean_b ? math.inf_f64(1) : math.inf_f64(-1), f64(n_a + n_b - 2)
	}
	t = (mean_a - mean_b) / math.sqrt(se_sq)
	denom := (va * va) / f64(n_a - 1) + (vb * vb) / f64(n_b - 1)
	df = denom > 0 ? (se_sq * se_sq) / denom : f64(n_a + n_b - 2)
	return
}

/*
Mann-Whitney U test (Wilcoxon rank-sum test) of two independent samples.

Returns `u` for `a` (the number of pairs where the `a` value is larger, ties counting one
half), the normal-approximation `z` with tie and continuity corrections (positive when `a`
tends to be larger), and the two-sided `p` value. Ranks only depend on the order of the
values, so a few extreme samples can't hide a shift of the bulk the way they inflate a
standard deviation. Fewer than two values on a side give `p = 1`.

The sorted copies are allocated with `allocator` and freed before returning.
*/
@(require_results)
mann_whitney_u :: proc(
	a, b: []f64,
	allocator := context.temp_allocator,
) -> (
	u: f64,
	z: f64,
	p: f64,
) {
	n1, n2 := len(a), len(b)
	if n1 < 2 || n2 < 2 {
		return 0, 0, 1
	}
	sa := slice.clone(a, allocator)
	defer delete(sa, allocator)
	sb := slice.clone(b, allocator)
	defer delete(sb, allocator)
	slice.sort(sa)
	slice.sort(sb)

	// Merge the sorted samples, giving every group of equal values its average rank.
	rank_sum_a: f64 = 0
	tie_term: f64 = 0
	i, j := 0, 0
	next_rank := 1
	for i < n1 || j < n2 {
		v: f64
		switch {
		case i >= n1:
			v = sb[j]
		case j >= n2:
			v = sa[i]
		case:
			v = min(sa[i], sb[j])
		}
		count_a, count_b := 0, 0
		for i + count_a < n1 && sa[i + count_a] == v {
			count_a += 1
		}
		for j + count_b < n2 && sb[j + count_b] == v {
			count_b += 1
		}
		tied := f64(count_a + count_b)
		rank_sum_a += f64(count_a) * (f64(next_rank) + (tied - 1) / 2)
		tie_term += tied * tied * tied - tied
		next_rank += count_a + count_b
		i += count_a
		j += count_b
	}

	f1, f2 := f64(n1), f64(n2)
	n := f1 + f2
	u = rank_sum_a - f1 * (f1 + 1) / 2
	variance := f1 * f2 / 12 * ((n + 1) - tie_term / (n * (n - 1)))
	if variance <= 0 {
		return u, 0, 1
	}
	shift := u - f1 * f2 / 2
	z = max(abs(shift) - 0.5, 0) / math.sqrt(variance)
	if shift < 0 {
		z = -z
	}
	p = math.erfc(abs(z) / math.SQRT_TWO)
	return u, z, p
}

/*
Compares `current` stats against `baseline` stats.

A change is significant when the samples differ at the 5% level and the median moved by at
least `noise_threshold_pct` percent (e.g. `2.0` for 2%). When both sides carry their
samples (`samples_ns`), the test is the Mann-Whitney U test. Otherwise, as for reports
written before format version 3, Welch's t-test on the means and standard deviations is
used, with the Welch-Satterthwaite degrees of freedom. The Welch statistic is filled in
either way.

The rank test sorts copies of the samples with `allocator`.
*/
@(require_results)
compare_baseline :: proc(
	current: Stats,
	baseline: Stats,
	noise_threshold_pct: f64 = 2.0,
	allocator := context.temp_allocator,
) -> Baseline_Diff {
	if baseline.samples <= 0 || baseline.p50_ns <= 0 || baseline.mean_ns <= 0 {
		return Baseline_Diff{has_baseline = false}
	}

	delta_median := ((current.p50_ns - baseline.p50_ns) / baseline.p50_ns) * 100.0
	delta_mean := ((current.mean_ns - baseline.mean_ns) / baseline.mean_ns) * 100.0

	delta_allocs: f64 = 0
	if baseline.allocs_per_op > 0 {
		delta_allocs =
			((current.allocs_per_op - baseline.allocs_per_op) / baseline.allocs_per_op) * 100.0
	} else if current.allocs_per_op > 0 {
		delta_allocs = 100.0
	}

	delta_bytes: f64 = 0
	if baseline.alloc_bytes_per_op > 0 {
		delta_bytes =
			((current.alloc_bytes_per_op - baseline.alloc_bytes_per_op) /
				baseline.alloc_bytes_per_op) *
			100.0
	} else if current.alloc_bytes_per_op > 0 {
		delta_bytes = 100.0
	}

	welch_t, welch_df := welch_test(
		current.mean_ns,
		current.std_dev_ns,
		current.samples,
		baseline.mean_ns,
		baseline.std_dev_ns,
		baseline.samples,
	)
	rank_test := len(current.samples_ns) >= 2 && len(baseline.samples_ns) >= 2
	p_value: f64 = 1
	samples_differ: bool
	if rank_test {
		_, _, p_value = mann_whitney_u(current.samples_ns, baseline.samples_ns, allocator)
		samples_differ = p_value < 0.05
	} else {
		samples_differ = welch_df > 0 && abs(welch_t) >= t_critical_975(welch_df)
	}
	significant := samples_differ && abs(delta_median) >= noise_threshold_pct

	return Baseline_Diff {
		has_baseline = true,
		delta_median_pct = delta_median,
		delta_mean_pct = delta_mean,
		delta_allocs_pct = delta_allocs,
		delta_bytes_pct = delta_bytes,
		welch_t = welch_t,
		welch_df = welch_df,
		rank_test = rank_test,
		p_value = rank_test ? p_value : 0,
		is_significant = significant,
		is_regression = significant && delta_median > 0,
		is_improvement = significant && delta_median < 0,
	}
}

/*
Computes geometric mean and baseline diff counts across a slice of benchmark results.
*/
@(require_results)
compute_suite_summary :: proc "contextless" (results: []Result) -> Suite_Summary {
	summary := Suite_Summary {
		total_benchmarks = len(results),
	}
	if len(results) == 0 {
		return summary
	}

	log_sum: f64 = 0
	valid_count := 0

	ratio_log_sum: f64 = 0
	diff_count := 0

	for r in results {
		if r.stats.p50_ns > 0 {
			log_sum += math.ln(r.stats.p50_ns)
			valid_count += 1
		}
		if r.diff.has_baseline {
			ratio := 1.0 + (r.diff.delta_median_pct / 100.0)
			if ratio > 0 {
				ratio_log_sum += math.ln(ratio)
				diff_count += 1
			}
			if r.diff.is_improvement {
				summary.improvements += 1
			} else if r.diff.is_regression {
				summary.regressions += 1
			} else {
				summary.unchanged += 1
			}
		}
	}

	if valid_count > 0 {
		summary.geomean_ns = math.exp(log_sum / f64(valid_count))
	}
	if diff_count > 0 {
		summary.has_baseline_diff = true
		summary.geomean_delta_pct = (math.exp(ratio_log_sum / f64(diff_count)) - 1.0) * 100.0
	}

	return summary
}
