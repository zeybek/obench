package obench

import "core:math"

/*
Asymptotic time-complexity classes supported by `estimate_complexity`.
*/
Complexity_Class :: enum {
	None = 0,
	O_1,
	O_Log_N,
	O_N,
	O_N_Log_N,
	O_N2,
	O_N3,
}

/*
Result of fitting a benchmark's parameterized scaling curve $(N_i, T_i)$ against
standard asymptotic complexity classes, as $T(N) \approx a + c \cdot f(N)$.
*/
Complexity_Estimate :: struct {
	bench_name:  string,
	group_name:  string,
	best_class:  Complexity_Class,
	coefficient: f64, // Scaling factor `c` in `T(N) ≈ a + c * f(N)` (in nanoseconds); the mean time for O(1)
	intercept:   f64, // Fixed cost `a` in `T(N) ≈ a + c * f(N)` (in nanoseconds); 0 for O(1)
	nrmse:       f64, // Normalized Root Mean Square Error (lower is better; 0.0 = exact fit)
	r_squared:   f64, // Coefficient of determination R^2 in [0.0, 1.0]
}

/*
Returns the human-readable Big-O notation string for a `Complexity_Class`.
*/
@(require_results)
complexity_string :: proc "contextless" (c: Complexity_Class) -> string {
	switch c {
	case .None:
		return "-"
	case .O_1:
		return "O(1)"
	case .O_Log_N:
		return "O(log N)"
	case .O_N:
		return "O(N)"
	case .O_N_Log_N:
		return "O(N log N)"
	case .O_N2:
		return "O(N^2)"
	case .O_N3:
		return "O(N^3)"
	}
	return "-"
}

@(private = "file")
_eval_curve :: proc "contextless" (c: Complexity_Class, n: f64) -> f64 {
	safe_n := max(n, 2.0)
	switch c {
	case .None, .O_1:
		return 1.0
	case .O_Log_N:
		return math.log2(safe_n)
	case .O_N:
		return n
	case .O_N_Log_N:
		return n * math.log2(safe_n)
	case .O_N2:
		return n * n
	case .O_N3:
		return n * n * n
	}
	return 1.0
}

// Upper 5% critical value of the F(1, df) distribution, the square of the two-sided 5% t.
@(private = "file")
_f_critical_1 :: proc "contextless" (df: int) -> f64 {
	t := t_critical_975(f64(df))
	return t * t
}

/*
Fits $M \ge 3$ parameterized measurements $(N_i, T_i)$ to the best-matching `Complexity_Class`.

Every growing class is fitted by least squares as $T_i \approx a + c \cdot f(N_i)$ with
$a, c \ge 0$, so a fixed cost per call doesn't distort the slope. A growing class only
counts when it explains the times significantly better than a constant (an F-test at the 5%
level against the O(1) fit); among those, the lowest NRMSE wins, with a 0.5% margin in
favor of the lower class. When no growing class passes, the result is O(1).
*/
@(require_results)
estimate_complexity :: proc "contextless" (
	group_name: string,
	bench_name: string,
	params: []int,
	times_ns: []f64,
) -> (
	est: Complexity_Estimate,
	ok: bool,
) {
	m := len(params)
	if m < 3 || len(times_ns) != m {
		return est, false
	}

	// A fit needs at least 3 distinct input sizes to tell curves apart.
	unique_params := 0
	outer: for p, i in params {
		for j in 0 ..< i {
			if params[j] == p {
				continue outer
			}
		}
		unique_params += 1
	}
	if unique_params < 3 {
		return est, false
	}

	mean_t: f64 = 0
	for t in times_ns {
		if t <= 0 {
			return est, false
		}
		mean_t += t
	}
	mean_t /= f64(m)

	ss_tot: f64 = 0
	for t in times_ns {
		d := t - mean_t
		ss_tot += d * d
	}

	const_nrmse := math.sqrt(ss_tot / f64(m)) / mean_t
	est = Complexity_Estimate {
		bench_name  = bench_name,
		group_name  = group_name,
		best_class  = .O_1,
		coefficient = mean_t,
		nrmse       = const_nrmse,
		r_squared   = clamp(1.0 - const_nrmse * const_nrmse, 0.0, 1.0),
	}

	f_crit := _f_critical_1(m - 2)
	best_nrmse := max(f64)
	growing := [?]Complexity_Class{.O_Log_N, .O_N, .O_N_Log_N, .O_N2, .O_N3}
	for cand in growing {
		mean_f: f64 = 0
		for p in params {
			mean_f += _eval_curve(cand, f64(p))
		}
		mean_f /= f64(m)
		sxx, sxy: f64 = 0, 0
		for p, i in params {
			dx := _eval_curve(cand, f64(p)) - mean_f
			sxx += dx * dx
			sxy += dx * (times_ns[i] - mean_t)
		}
		if sxx <= 0 || sxy <= 0 {
			continue // The times don't grow along this curve.
		}
		coeff := sxy / sxx
		intercept := mean_t - coeff * mean_f
		if intercept < 0 {
			// The best line crosses below zero: fit through the origin instead.
			num, den: f64 = 0, 0
			for p, i in params {
				fn := _eval_curve(cand, f64(p))
				num += times_ns[i] * fn
				den += fn * fn
			}
			coeff = num / den
			intercept = 0
		}

		ss_res: f64 = 0
		for p, i in params {
			err := times_ns[i] - (intercept + coeff * _eval_curve(cand, f64(p)))
			ss_res += err * err
		}
		if ss_res >= ss_tot {
			continue
		}
		// F = (SS_const - SS_fit) / (SS_fit / (m - 2)), infinite for an exact fit.
		if ss_res > 0 && (ss_tot - ss_res) * f64(m - 2) <= f_crit * ss_res {
			continue
		}

		nrmse := math.sqrt(ss_res / f64(m)) / mean_t
		if nrmse + 0.005 < best_nrmse {
			best_nrmse = nrmse
			est.best_class = cand
			est.coefficient = coeff
			est.intercept = intercept
			est.nrmse = nrmse
			est.r_squared = clamp(1.0 - ss_res / ss_tot, 0.0, 1.0)
		}
	}
	return est, true
}
