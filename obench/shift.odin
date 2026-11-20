package obench

import "base:runtime"
import "core:math"
import "core:slice"

/*
Lag-1 autocorrelation of `samples` in the order they were taken: about 0 for independent
samples, and positive when a slow sample tends to follow a slow one. Returns 0 for fewer than
three samples or when they are all the same.
*/
@(require_results)
lag1_autocorrelation :: proc "contextless" (samples: []f64) -> f64 {
	n := len(samples)
	if n < 3 {
		return 0
	}
	mean: f64 = 0
	for v in samples {
		mean += v
	}
	mean /= f64(n)
	num, den: f64 = 0, 0
	for v, i in samples {
		d := v - mean
		den += d * d
		if i + 1 < n {
			num += d * (samples[i + 1] - mean)
		}
	}
	if den <= 0 {
		return 0
	}
	return num / den
}

// Samples up to this many per side use the exact distribution of the Mann-Whitney U statistic.
@(private = "file")
EXACT_U_LIMIT :: 20

// Above this many pairwise differences, each side is thinned to evenly spaced quantiles.
@(private = "file")
MAX_PAIRS :: 1_000_000

/*
Number of the smallest pairwise differences that lie below a two-sided 95% interval for
samples of `n` and `m` values without ties: the largest `k` with P(U < k) <= 0.025 under the
null hypothesis, from the exact distribution of U.
*/
@(private = "file")
_exact_u_cut :: proc(n, m: int, allocator := context.temp_allocator) -> int {
	// counts[i][j][u]: orderings of i values against j values with U = u, flattened.
	stride := n * m + 1
	counts := make([]f64, (n + 1) * (m + 1) * stride, allocator)
	defer delete(counts, allocator)
	at :: #force_inline proc(counts: []f64, i, j, u, m, stride: int) -> ^f64 {
		return &counts[(i * (m + 1) + j) * stride + u]
	}
	for i in 0 ..= n {
		for j in 0 ..= m {
			if i == 0 || j == 0 {
				at(counts, i, j, 0, m, stride)^ = 1
				continue
			}
			for u in 0 ..= i * j {
				v: f64 = 0
				if u >= j {
					v += at(counts, i - 1, j, u - j, m, stride)^
				}
				if u <= i * (j - 1) {
					v += at(counts, i, j - 1, u, m, stride)^
				}
				at(counts, i, j, u, m, stride)^ = v
			}
		}
	}
	total: f64 = 0
	for u in 0 ..= n * m {
		total += at(counts, n, m, u, m, stride)^
	}
	cum: f64 = 0
	k := 0
	for u in 0 ..= n * m {
		cum += at(counts, n, m, u, m, stride)^
		if cum / total > 0.025 {
			break
		}
		k = u + 1
	}
	return k
}

// Up to `limit` evenly spaced quantiles of the sorted `values`.
@(private = "file")
_thin :: proc(values: []f64, limit: int, allocator := context.temp_allocator) -> []f64 {
	if len(values) <= limit {
		return values
	}
	out := make([]f64, limit, allocator)
	for i in 0 ..< limit {
		out[i] = values[i * (len(values) - 1) / (limit - 1)]
	}
	return out
}

/*
Hodges-Lehmann estimate of how much `current` moved against `baseline`, as a percent change of
the typical sample, with its distribution-free 95% confidence interval: the median and two
order statistics of every pairwise log ratio, the interval the Mann-Whitney U test inverts.
Up to 20 samples a side use the exact distribution of U, and more use its normal
approximation. Samples are rarely independent, since one slow stretch of the machine covers
several of them, so with `adjust_for_autocorrelation` the normal approximation uses each
side's effective sample count, n(1 - r)/(1 + r) for a positive lag-1 autocorrelation r, which
widens the interval. `ok` is false with fewer than two samples on a side.

Copies of the samples are sorted with `allocator`.
*/
@(require_results)
hodges_lehmann_shift :: proc(
	current, baseline: []f64,
	adjust_for_autocorrelation := true,
	allocator := context.temp_allocator,
) -> (
	shift_pct, low_pct, high_pct: f64,
	ok: bool,
) {
	n, m := len(current), len(baseline)
	if n < 2 || m < 2 {
		return
	}
	// The log of a sample clamped to 0 would be -inf; a femtosecond keeps the ratio finite.
	FLOOR :: 1e-6
	logs :: proc(values: []f64, allocator: runtime.Allocator) -> []f64 {
		out := make([]f64, len(values), allocator)
		for v, i in values {
			out[i] = math.ln(max(v, FLOOR))
		}
		slice.sort(out)
		return out
	}
	lx := logs(current, allocator)
	defer delete(lx, allocator)
	ly := logs(baseline, allocator)
	defer delete(ly, allocator)
	tx, ty := lx, ly
	if n * m > MAX_PAIRS {
		side := int(math.sqrt(f64(MAX_PAIRS)))
		tx = _thin(lx, side, allocator)
		ty = _thin(ly, side, allocator)
	}
	defer if len(tx) != len(lx) {delete(tx, allocator)}
	defer if len(ty) != len(ly) {delete(ty, allocator)}

	diffs := make([]f64, len(tx) * len(ty), allocator)
	defer delete(diffs, allocator)
	for x, i in tx {
		for y, j in ty {
			diffs[i * len(ty) + j] = x - y
		}
	}
	slice.sort(diffs)
	total := len(diffs)
	median := (diffs[(total - 1) / 2] + diffs[total / 2]) / 2

	// `k` differences on each side fall outside the interval: [D(k), D(N - k + 1)], 1-indexed.
	k: int
	if len(tx) <= EXACT_U_LIMIT && len(ty) <= EXACT_U_LIMIT {
		k = _exact_u_cut(len(tx), len(ty), allocator)
	} else {
		ne, me := f64(len(tx)), f64(len(ty))
		if adjust_for_autocorrelation {
			effective :: proc(count: f64, autocorrelation: f64) -> f64 {
				r := clamp(autocorrelation, 0, 0.95)
				return max(count * (1 - r) / (1 + r), 2)
			}
			ne = effective(ne, lag1_autocorrelation(current))
			me = effective(me, lag1_autocorrelation(baseline))
		}
		Z_975 :: 1.959963984540054
		big_n := f64(total)
		k = int(math.floor(big_n / 2 - Z_975 * big_n * math.sqrt((ne + me + 1) / (12 * ne * me))))
	}
	k = clamp(k, 1, total / 2)
	pct :: proc(log_ratio: f64) -> f64 {
		return (math.exp(log_ratio) - 1) * 100
	}
	return pct(median), pct(diffs[k - 1]), pct(diffs[total - k]), true
}
