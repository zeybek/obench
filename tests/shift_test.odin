package obench_tests

import obench "../obench"
import "core:testing"

@(private = "file")
_near :: proc(t: ^testing.T, got, want: f64, what: string, loc := #caller_location) {
	testing.expectf(
		t,
		abs(got - want) < 1e-6,
		"%s: got %.9f, want %.9f",
		what,
		got,
		want,
		loc = loc,
	)
}

// The expected values come from a separate Python implementation of the same estimator:
// every pairwise log ratio, the exact distribution of U up to 20 samples a side, and
// k = floor(N/2 - z * N * sqrt((n + m + 1) / (12 n m))) above that.
@(test)
test_hodges_lehmann_shift_matches_a_reference :: proc(t: ^testing.T) {
	x := []f64{101, 104, 99, 107, 103, 100, 108, 102}
	y := []f64{96, 95, 98, 93, 97, 94, 99, 92}
	shift, low, high, ok := obench.hodges_lehmann_shift(x, y)
	testing.expect(t, ok)
	_near(t, shift, 7.567780908044508, "8 vs 8 shift")
	_near(t, low, 4.1666666666667185, "8 vs 8 low (exact U)")
	_near(t, high, 11.340206185567038, "8 vs 8 high (exact U)")

	xs := []f64 {
		104.74412,
		105.511432,
		104.773904,
		104.684932,
		104.069982,
		104.786698,
		106.111917,
		105.424147,
		106.036879,
		105.248903,
		105.39477,
		105.185327,
		103.333937,
		105.855251,
		105.506385,
		105.498818,
		103.308635,
		103.256112,
		104.110385,
		104.531811,
		105.305446,
		104.954088,
		105.520975,
		104.357765,
		105.308703,
		105.394154,
		104.338863,
		106.71753,
		105.556609,
		106.197005,
		104.379667,
		104.260484,
		104.655953,
		104.893579,
		105.632079,
		105.248427,
		104.552645,
		104.043088,
		104.47941,
		106.220921,
		104.192054,
		105.244759,
		105.426519,
		103.510257,
		105.048474,
		106.306244,
		102.985636,
		104.678406,
		104.893861,
		104.18274,
	}
	ys := []f64 {
		100.49739,
		99.93772,
		98.535343,
		100.827846,
		100.669336,
		100.945842,
		101.440597,
		100.362244,
		100.119274,
		98.700832,
		100.615443,
		99.388241,
		99.547298,
		98.735212,
		99.032386,
		99.468879,
		101.288838,
		97.968208,
		98.542294,
		100.239351,
		101.44335,
		100.578497,
		98.100057,
		97.481765,
		100.357397,
		99.263738,
		98.880213,
		100.977371,
		101.101786,
		100.157252,
		100.245777,
		100.434363,
		101.594004,
		100.619029,
		100.51865,
		100.547738,
		98.431689,
		101.281734,
		100.955102,
		100.529624,
		98.026125,
		99.36632,
		100.842304,
		98.188786,
		99.815978,
		101.019528,
		98.688811,
		101.610106,
		100.551964,
		99.849861,
	}
	shift, low, high, ok = obench.hodges_lehmann_shift(xs, ys, adjust_for_autocorrelation = false)
	testing.expect(t, ok)
	_near(t, shift, 4.848347754540305, "50 vs 50 shift")
	_near(t, low, 4.434640797926703, "50 vs 50 low (normal)")
	_near(t, high, 5.274175448683893, "50 vs 50 high (normal)")

	// Positive autocorrelation only ever widens the interval.
	_, adj_low, adj_high, _ := obench.hodges_lehmann_shift(xs, ys)
	testing.expect(t, adj_low <= low && adj_high >= high)
}

@(test)
test_hodges_lehmann_shift_of_the_same_samples_contains_zero :: proc(t: ^testing.T) {
	x := []f64{10, 12, 11, 13, 9, 10, 12, 11, 10, 14}
	shift, low, high, ok := obench.hodges_lehmann_shift(x, x)
	testing.expect(t, ok)
	_near(t, shift, 0, "shift")
	testing.expect(t, low < 0 && high > 0, "the interval contains no change")
	_, _, _, ok = obench.hodges_lehmann_shift(x[:1], x)
	testing.expect(t, !ok, "one sample is not enough")
}

@(test)
test_lag1_autocorrelation :: proc(t: ^testing.T) {
	testing.expect(t, obench.lag1_autocorrelation([]f64{1, 2, 3, 4, 5, 6, 7, 8}) > 0.5)
	testing.expect(t, obench.lag1_autocorrelation([]f64{1, 9, 1, 9, 1, 9, 1, 9}) < -0.5)
	testing.expect_value(t, obench.lag1_autocorrelation([]f64{3, 3, 3, 3}), 0)
}

@(private = "file")
_sample_stats :: proc(values: []f64) -> obench.Stats {
	return obench.compute_stats(values, values, 1, u64(len(values)), 0, 0, nil, nil)
}

// A 3% shift whose interval reaches down to 1.5%: p is 0.0013, so the old rule (p < 0.05 and
// the median moved by more than 2%) flagged it. The interval rule doesn't, until the whole
// shift clears the threshold.
@(test)
test_regression_needs_the_whole_interval_above_the_threshold :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	base := []f64{100, 101, 99, 102, 98, 100.5, 99.5, 101.5, 98.5, 100}
	near := []f64{103, 104.854, 101.146, 105.678, 100.322, 103.927, 102.073, 104.236, 101.764, 103}
	diff := obench.compare_baseline(_sample_stats(near), _sample_stats(base), 2.0)
	testing.expect(t, diff.p_value < 0.05)
	testing.expect(t, diff.delta_median_pct > 2.0)
	testing.expect(
		t,
		diff.shift_low_pct < 2.0 && diff.shift_high_pct > 2.0,
		"the interval straddles 2%",
	)
	testing.expect(t, !diff.is_regression && !diff.is_significant)

	far := make([]f64, len(base), context.temp_allocator)
	for v, i in base {
		far[i] = v * 1.10
	}
	diff = obench.compare_baseline(_sample_stats(far), _sample_stats(base), 2.0)
	testing.expect(t, diff.shift_low_pct > 2.0)
	testing.expect(t, diff.is_regression)
	diff = obench.compare_baseline(_sample_stats(base), _sample_stats(far), 2.0)
	testing.expect(t, diff.shift_high_pct < -2.0)
	testing.expect(t, diff.is_improvement)
}

// With 2 samples against 2, the two sides are completely apart in 2 of the 6 possible orders,
// so even the smallest and the largest ratio cover only 67%. There is a 95% interval once
// the smallest tail of the exact distribution is 2.5% or less: 1/70 for 4 against 4.
@(test)
test_too_few_samples_have_no_interval :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	base := []f64{100, 101, 102, 103, 104, 105, 106, 107}
	slower := []f64{110, 111, 112, 113, 114, 115, 116, 117}
	cases := []struct {
		n, m:         int,
		has_interval: bool,
	} {
		{2, 2, false},
		{3, 3, false},
		{2, 7, false},
		{3, 4, false},
		{4, 4, true},
		{2, 8, true},
		{3, 5, true},
		{8, 8, true},
	}
	for c in cases {
		_, low, high, ok := obench.hodges_lehmann_shift(slower[:c.n], base[:c.m])
		testing.expectf(t, ok == c.has_interval, "%d against %d: ok is %v", c.n, c.m, ok)
		testing.expectf(t, low > 0 && high > low, "%d against %d: %v to %v", c.n, c.m, low, high)
	}
}

@(private = "file")
_process_stats :: proc(medians: []f64) -> obench.Stats {
	return obench.Stats {
		samples = len(medians),
		p50_ns = medians[len(medians) / 2],
		mean_ns = medians[len(medians) / 2],
		samples_ns = medians,
		process_medians_ns = medians,
	}
}

// Both processes are about 5% slower and every ratio is above the 2% threshold, but 2 against
// 2 can't decide anything.
@(test)
test_two_processes_a_side_decide_nothing :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	diff := obench.compare_baseline(_process_stats({105, 106}), _process_stats({100, 101}), 2.0)
	testing.expect(t, diff.too_few_samples)
	testing.expect(t, diff.shift_low_pct > 2.0, "the smallest ratio is above the threshold")
	testing.expect(t, !diff.is_regression && !diff.is_improvement && !diff.is_significant)

	diff = obench.compare_baseline(
		_process_stats({110, 111, 112, 113}),
		_process_stats({100, 101, 102, 103}),
		2.0,
	)
	testing.expect(t, !diff.too_few_samples)
	testing.expect(t, diff.is_regression)
}
