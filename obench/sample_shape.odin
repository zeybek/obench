package obench

import "core:math"
import "core:slice"

/*
How many independent samples `n` samples with lag-1 autocorrelation r are worth:
n(1 - r)/(1 + r) for a positive r, the effective sample size of an AR(1) process, and `n`
otherwise. Never below 2 (for `n >= 2`). At r = 0.4, 50 samples are worth about 21.
*/
@(require_results)
effective_sample_count :: proc "contextless" (n: int, autocorrelation: f64) -> f64 {
	if n < 2 {
		return f64(n)
	}
	r := clamp(autocorrelation, 0, 0.95)
	return clamp(f64(n) * (1 - r) / (1 + r), 2, f64(n))
}

// O(n²) shape statistics look at no more than this many samples.
@(private = "file")
SHAPE_LIMIT :: 1000

/*
Whether `samples`, in the order they were taken, drift over the run. `change_pct` is the
Theil-Sen slope (the median slope between every pair of samples) times the run's length, as a
percent of the median sample: the change from the first sample to the last. `z` is the
Mann-Kendall statistic for a monotonic trend, with its variance raised by (1 + r)/(1 - r)
for a positive lag-1 autocorrelation r of the samples with the trend taken out, since
correlated samples look like a trend more often. |z| > 2.576 is significant at the 1% level. Both are 0 for fewer than 8 samples.
More than 1,000 samples are thinned to every k-th one.
*/
@(require_results)
sample_trend :: proc(
	samples: []f64,
	allocator := context.temp_allocator,
) -> (
	change_pct: f64,
	z: f64,
) {
	n_all := len(samples)
	if n_all < 8 {
		return
	}
	step := max(1, (n_all + SHAPE_LIMIT - 1) / SHAPE_LIMIT)
	n := (n_all + step - 1) / step
	x := make([]f64, n, allocator)
	defer delete(x, allocator)
	for i in 0 ..< n {
		x[i] = samples[i * step]
	}

	s: f64 = 0
	slopes := make([]f64, n * (n - 1) / 2, allocator)
	defer delete(slopes, allocator)
	k := 0
	for i in 0 ..< n {
		for j in i + 1 ..< n {
			d := x[j] - x[i]
			s += f64(int(d > 0)) - f64(int(d < 0))
			slopes[k] = d / f64((j - i) * step)
			k += 1
		}
	}

	// Variance of S with the correction for tied values.
	sorted := slice.clone(x, allocator)
	defer delete(sorted, allocator)
	slice.sort(sorted)
	nf := f64(n)
	variance := nf * (nf - 1) * (2 * nf + 5)
	for i := 0; i < n; {
		t := 1
		for i + t < n && sorted[i + t] == sorted[i] {
			t += 1
		}
		tf := f64(t)
		variance -= tf * (tf - 1) * (2 * tf + 5)
		i += t
	}
	variance /= 18

	slice.sort(slopes)
	m := len(slopes)
	slope := (slopes[(m - 1) / 2] + slopes[m / 2]) / 2

	// The autocorrelation of what's left after taking the trend out: a trend alone makes
	// neighbouring samples look alike, which would hide the trend it comes from.
	for i in 0 ..< n {
		x[i] -= slope * f64(i * step)
	}
	r := clamp(lag1_autocorrelation(x), 0, 0.95)
	variance *= (1 + r) / (1 - r)
	if variance > 0 && s != 0 {
		z = (s - math.sign(s)) / math.sqrt(variance)
	}
	median := percentile_sorted(sorted, 0.5)
	if median > 0 {
		change_pct = slope * f64(n_all - 1) / median * 100
	}
	return
}

/*
Number of separate peaks in the distribution of `samples`: 2 when the samples fall into two
groups, as when part of a run hit a slower code path or another CPU core. It counts the peaks
of a Gaussian kernel density estimate (Silverman's bandwidth, between the 1st and 99th
percentile) that reach a quarter of the highest one, and merges two peaks unless the density
between them drops below 70% of the lower one. Returns 1 for fewer than 20 samples or when
they barely vary.
*/
@(require_results)
count_modes :: proc(samples: []f64, allocator := context.temp_allocator) -> int {
	n := len(samples)
	if n < 20 {
		return 1
	}
	sorted := slice.clone(samples, allocator)
	defer delete(sorted, allocator)
	slice.sort(sorted)

	mean: f64 = 0
	for v in sorted {
		mean += v
	}
	mean /= f64(n)
	sq: f64 = 0
	for v in sorted {
		sq += (v - mean) * (v - mean)
	}
	sd := math.sqrt(sq / f64(n - 1))
	iqr := percentile_sorted(sorted, 0.75) - percentile_sorted(sorted, 0.25)
	spread := min(sd, iqr / 1.34)
	if spread <= 0 || mean <= 0 || spread < mean * 1e-6 {
		return 1
	}
	h := 0.9 * spread * math.pow(f64(n), -0.2)

	// The density over the bulk of the samples; outliers beyond p1 and p99 don't stretch it.
	GRID :: 512
	lo := percentile_sorted(sorted, 0.01) - 3 * h
	hi := percentile_sorted(sorted, 0.99) + 3 * h
	points := sorted
	if n > 2 * SHAPE_LIMIT {
		points = make([]f64, 2 * SHAPE_LIMIT, allocator)
		for i in 0 ..< len(points) {
			points[i] = sorted[i * (n - 1) / (len(points) - 1)]
		}
	}
	defer if len(points) != n {delete(points, allocator)}
	density: [GRID]f64
	for g in 0 ..< GRID {
		at := lo + (hi - lo) * f64(g) / (GRID - 1)
		sum: f64 = 0
		for v in points {
			u := (at - v) / h
			if abs(u) < 6 {
				sum += math.exp(-0.5 * u * u)
			}
		}
		density[g] = sum
	}

	highest: f64 = 0
	for d in density {
		highest = max(highest, d)
	}
	modes := 0
	last_peak := -1
	for g in 1 ..< GRID - 1 {
		if !(density[g] > density[g - 1] && density[g] >= density[g + 1]) {
			continue
		}
		if density[g] < 0.25 * highest {
			continue
		}
		if last_peak < 0 {
			modes = 1
			last_peak = g
			continue
		}
		valley := density[last_peak]
		for v in last_peak ..= g {
			valley = min(valley, density[v])
		}
		if valley < 0.7 * min(density[last_peak], density[g]) {
			modes += 1
			last_peak = g
		} else if density[g] > density[last_peak] {
			last_peak = g
		}
	}
	return max(modes, 1)
}
