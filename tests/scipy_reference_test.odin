package obench_tests

import obench "../obench"
import "core:encoding/json"
import "core:fmt"
import "core:testing"

// Expected values computed by numpy and scipy; regenerate with `make reference`
// (see scripts/scipy_reference.py).
@(private = "file")
REFERENCE_JSON :: #load("testdata/scipy_reference.json")

@(private = "file")
Ref_Sample :: struct {
	values:         []f64,
	lo:             f64 `json:"min"`,
	hi:             f64 `json:"max"`,
	mean:           f64,
	std_dev:        f64,
	ci95:           f64,
	p25:            f64,
	p50:            f64,
	p75:            f64,
	p95:            f64,
	p99:            f64,
	mad:            f64,
	low_outliers:   int,
	high_outliers:  int,
	check_outliers: bool,
}

@(private = "file")
Ref_Pair :: struct {
	a, b:              int,
	welch_t:           f64,
	welch_df:          f64,
	u:                 f64,
	p:                 f64,
	abs_z:             f64,
	z_sign:            int,
	rank_significant:  bool,
	welch_significant: bool,
}

@(private = "file")
Ref_Complexity :: struct {
	params:      []int,
	times:       []f64,
	class:       string,
	coefficient: f64,
	intercept:   f64,
	nrmse:       f64,
	r_squared:   f64,
}

@(private = "file")
Reference :: struct {
	t_quantiles: []struct {
		df, t: f64,
	},
	samples:     []Ref_Sample,
	pairs:       []Ref_Pair,
	complexity:  []Ref_Complexity,
	geomean:     struct {
		values:  []f64,
		geomean: f64,
	},
}

@(private = "file")
_load_reference :: proc(t: ^testing.T) -> (ref: Reference, ok: bool) {
	err := json.unmarshal(REFERENCE_JSON, &ref, allocator = context.temp_allocator)
	testing.expectf(t, err == nil, "parsing scipy_reference.json: %v", err)
	return ref, err == nil
}

// |got - want| within `rel` of |want|, or within `abs_tol` for values near zero.
@(private = "file")
_close :: proc(got, want, rel: f64, abs_tol: f64 = 0) -> bool {
	return abs(got - want) <= max(rel * abs(want), abs_tol)
}

@(private = "file")
_stats_of :: proc(values: []f64) -> obench.Stats {
	return obench.compute_stats(values, values, 1, u64(len(values)), 0, 0, nil, nil)
}

@(test)
test_t_quantiles_match_scipy :: proc(t: ^testing.T) {
	ref, ok := _load_reference(t)
	if !ok {
		return
	}
	testing.expect(t, len(ref.t_quantiles) > 0)
	for q in ref.t_quantiles {
		got := obench.t_critical_975(q.df)
		testing.expectf(t, _close(got, q.t, 1e-9), "df=%v: got %.12f, scipy %.12f", q.df, got, q.t)
	}
}

@(test)
test_sample_statistics_match_numpy :: proc(t: ^testing.T) {
	ref, ok := _load_reference(t)
	if !ok {
		return
	}
	testing.expect(t, len(ref.samples) > 0)
	for s, i in ref.samples {
		st := _stats_of(s.values)
		// A constant sample's deviation is zero in exact arithmetic and rounding noise in both.
		noise := 1e-12 * s.mean
		check :: proc(t: ^testing.T, i: int, name: string, got, want, rel, abs_tol: f64) {
			testing.expectf(
				t,
				_close(got, want, rel, abs_tol),
				"sample %d %s: got %.15g, numpy %.15g",
				i,
				name,
				got,
				want,
			)
		}
		check(t, i, "min", st.min_ns, s.lo, 0, 0)
		check(t, i, "max", st.max_ns, s.hi, 0, 0)
		check(t, i, "mean", st.mean_ns, s.mean, 1e-12, 0)
		check(t, i, "std_dev", st.std_dev_ns, s.std_dev, 1e-9, noise)
		check(t, i, "ci95", st.ci95_ns, s.ci95, 1e-9, noise)
		check(t, i, "p25", st.p25_ns, s.p25, 1e-12, 0)
		check(t, i, "p50", st.p50_ns, s.p50, 1e-12, 0)
		check(t, i, "p75", st.p75_ns, s.p75, 1e-12, 0)
		check(t, i, "p95", st.p95_ns, s.p95, 1e-12, 0)
		check(t, i, "p99", st.p99_ns, s.p99, 1e-12, 0)
		check(t, i, "mad", st.mad_ns, s.mad, 1e-12, noise)
		if s.check_outliers {
			testing.expectf(
				t,
				st.low_outliers == s.low_outliers && st.high_outliers == s.high_outliers,
				"sample %d outliers: got %d low / %d high, numpy %d / %d",
				i,
				st.low_outliers,
				st.high_outliers,
				s.low_outliers,
				s.high_outliers,
			)
		}
	}
}

@(test)
test_comparisons_match_scipy :: proc(t: ^testing.T) {
	ref, ok := _load_reference(t)
	if !ok {
		return
	}
	testing.expect(t, len(ref.pairs) > 0)
	for pr, i in ref.pairs {
		a := ref.samples[pr.a].values
		b := ref.samples[pr.b].values
		cur := _stats_of(a)
		base := _stats_of(b)

		u, z, p := obench.mann_whitney_u(a, b)
		testing.expectf(t, u == pr.u, "pair %d: U %v, scipy %v", i, u, pr.u)
		testing.expectf(
			t,
			_close(p, pr.p, 1e-9, 1e-300),
			"pair %d: p %.15g, scipy %.15g",
			i,
			p,
			pr.p,
		)
		testing.expectf(
			t,
			_close(abs(z), pr.abs_z, 1e-7, 1e-9),
			"pair %d: |z| %v, scipy %v",
			i,
			abs(z),
			pr.abs_z,
		)
		sign := z > 0 ? 1 : z < 0 ? -1 : 0
		testing.expectf(
			t,
			sign == pr.z_sign,
			"pair %d: sign of z %d, expected %d",
			i,
			sign,
			pr.z_sign,
		)

		wt, wdf := obench.welch_test(
			cur.mean_ns,
			cur.std_dev_ns,
			cur.samples,
			base.mean_ns,
			base.std_dev_ns,
			base.samples,
		)
		// Equal means leave t as rounding noise of either sign.
		testing.expectf(
			t,
			_close(wt, pr.welch_t, 1e-9, 1e-9),
			"pair %d: Welch t %v, scipy %v",
			i,
			wt,
			pr.welch_t,
		)
		testing.expectf(
			t,
			_close(wdf, pr.welch_df, 1e-9),
			"pair %d: Welch df %v, scipy %v",
			i,
			wdf,
			pr.welch_df,
		)

		diff := obench.compare_baseline(cur, base, 2.0)
		testing.expectf(
			t,
			diff.rank_test && diff.is_significant == pr.rank_significant,
			"pair %d: rank-test significance %v, scipy %v (p %v)",
			i,
			diff.is_significant,
			pr.rank_significant,
			pr.p,
		)

		// Reports written before format version 3 have no samples and use Welch's test.
		cur.samples_ns, base.samples_ns = nil, nil
		old := obench.compare_baseline(cur, base, 2.0)
		testing.expectf(
			t,
			!old.rank_test && old.is_significant == pr.welch_significant,
			"pair %d: Welch significance %v, scipy %v (t %v, df %v)",
			i,
			old.is_significant,
			pr.welch_significant,
			pr.welch_t,
			pr.welch_df,
		)
	}
}

@(test)
test_complexity_fits_match_numpy :: proc(t: ^testing.T) {
	ref, ok := _load_reference(t)
	if !ok {
		return
	}
	testing.expect(t, len(ref.complexity) > 0)
	for c, i in ref.complexity {
		est, fitted := obench.estimate_complexity("ref", "case", c.params, c.times)
		testing.expectf(t, fitted, "case %d: no fit", i)
		got := fmt.tprint(est.best_class)
		if !testing.expectf(t, got == c.class, "case %d: %s, numpy %s", i, got, c.class) {
			continue
		}
		mean_t: f64 = 0
		for v in c.times {
			mean_t += v
		}
		mean_t /= f64(len(c.times))
		testing.expectf(
			t,
			_close(est.coefficient, c.coefficient, 1e-6),
			"case %d: coefficient %v, numpy %v",
			i,
			est.coefficient,
			c.coefficient,
		)
		testing.expectf(
			t,
			_close(est.intercept, c.intercept, 1e-6, 1e-6 * mean_t),
			"case %d: intercept %v, numpy %v",
			i,
			est.intercept,
			c.intercept,
		)
		testing.expectf(
			t,
			_close(est.nrmse, c.nrmse, 1e-6, 1e-9),
			"case %d: NRMSE %v, numpy %v",
			i,
			est.nrmse,
			c.nrmse,
		)
		testing.expectf(
			t,
			_close(est.r_squared, c.r_squared, 1e-6, 1e-9),
			"case %d: R^2 %v, numpy %v",
			i,
			est.r_squared,
			c.r_squared,
		)
	}
}

@(test)
test_geomean_matches_scipy :: proc(t: ^testing.T) {
	ref, ok := _load_reference(t)
	if !ok {
		return
	}
	results := make([]obench.Result, len(ref.geomean.values), context.temp_allocator)
	for v, i in ref.geomean.values {
		results[i].stats.p50_ns = v
	}
	summary := obench.compute_suite_summary(results)
	testing.expectf(
		t,
		_close(summary.geomean_ns, ref.geomean.geomean, 1e-12),
		"geomean %v, scipy %v",
		summary.geomean_ns,
		ref.geomean.geomean,
	)
}
