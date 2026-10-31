# /// script
# requires-python = ">=3.12"
# dependencies = ["numpy==2.5.4", "scipy==1.18.1"]
# ///
"""Writes tests/testdata/scipy_reference.json, the expected values that
tests/scipy_reference_test.odin checks obench's statistics against.

Run it with `make reference` (needs uv: https://docs.astral.sh/uv/). The output only
depends on the seed and the pinned numpy and scipy versions. With `--check` it writes
nothing and fails when the committed file differs from a fresh run by more than the last
digits, which vary with the platform's math library; CI runs that.

The samples, the Welch and Mann-Whitney statistics, the t quantiles, and the geomean come
straight from numpy and scipy. scipy has no Big-O fitter, so the complexity cases come from
a second implementation of the rule `estimate_complexity` documents, built on
numpy.linalg.lstsq and scipy.stats.f. Cases whose outcome sits within rounding of a
decision threshold are drawn again, so a last-digit difference can't flip a decision.
"""

import json
import math
import pathlib
import sys
import warnings

import numpy as np
import scipy
from scipy import stats

SEED = 20261031
OUT = pathlib.Path(__file__).resolve().parent.parent / "tests" / "testdata" / "scipy_reference.json"
NOISE_THRESHOLD_PCT = 2.0
# Decisions whose margin is smaller than this (relative) are drawn again.
MARGIN = 1e-6

rng = np.random.default_rng(SEED)
# Constant samples are part of the data on purpose; scipy warns about their zero variance.
warnings.filterwarnings("ignore", message="Precision loss occurred")


def draw(kind, n, scale):
    if kind == "normal":
        v = rng.normal(scale, scale * 0.05, n)
    elif kind == "lognormal":
        v = scale * np.exp(rng.normal(0.0, 0.3, n))
    elif kind == "outliers":
        v = rng.normal(scale, scale * 0.02, n)
        hits = rng.random(n) < 0.1
        v[hits] *= 8.0
    elif kind == "ticks":
        # A 24 MHz clock: every value is a whole number of 41.67 ns ticks, so ties are common.
        tick = 1e9 / 24e6
        v = np.round(rng.normal(scale, scale * 0.05, n) / tick) * tick
    elif kind == "integers":
        v = np.round(rng.normal(scale, 2.0, n))
    elif kind == "constant":
        v = np.full(n, scale)
    else:
        raise ValueError(kind)
    # Six decimals (femtoseconds) keep the file small and still leave few accidental ties.
    return np.round(np.abs(v) + 1.0, 6)


def sample_entry(v):
    v = np.asarray(v, dtype=float)
    n = len(v)
    q25, q50, q75, q95, q99 = np.percentile(v, [25, 50, 75, 95, 99], method="linear")
    iqr = q75 - q25
    fences = [q25 - 1.5 * iqr, q75 + 1.5 * iqr]
    # A value on a fence counts as an outlier or not depending on the last digit of the fence.
    on_fence = any(abs(x - f) <= 1e-9 * abs(f) for x in v for f in fences)
    std = float(np.std(v, ddof=1)) if n > 1 else 0.0
    ci95 = float(stats.t.ppf(0.975, n - 1) * std / math.sqrt(n)) if n > 1 else 0.0
    return {
        "values": [float(x) for x in v],
        "min": float(v.min()),
        "max": float(v.max()),
        "mean": float(np.mean(v)),
        "std_dev": std,
        "ci95": ci95,
        "p25": float(q25),
        "p50": float(q50),
        "p75": float(q75),
        "p95": float(q95),
        "p99": float(q99),
        "mad": float(stats.median_abs_deviation(v, scale=1.0)),
        "low_outliers": int(np.sum(v < fences[0])),
        "high_outliers": int(np.sum(v > fences[1])),
        "check_outliers": not on_fence,
    }


def pair_entry(a, b):
    """`a` is the current run and `b` the baseline, as in compare_baseline(a, b)."""
    a, b = np.asarray(a), np.asarray(b)
    if np.var(a) == 0 and np.var(b) == 0:
        return None
    welch = stats.ttest_ind(a, b, equal_var=False)
    mw = stats.mannwhitneyu(a, b, alternative="two-sided", method="asymptotic", use_continuity=True)
    p = float(mw.pvalue)
    delta = (np.median(a) - np.median(b)) / np.median(b) * 100.0
    t_crit = stats.t.ppf(0.975, welch.df)
    # Too close to a threshold to compare decisions across implementations.
    if abs(p - 0.05) < MARGIN or abs(abs(delta) - NOISE_THRESHOLD_PCT) < MARGIN:
        return None
    if abs(abs(welch.statistic) / t_crit - 1.0) < MARGIN:
        return None
    shift = float(mw.statistic) - len(a) * len(b) / 2.0
    return {
        "welch_t": float(welch.statistic),
        "welch_df": float(welch.df),
        "u": float(mw.statistic),
        "p": p,
        "abs_z": float(stats.norm.isf(p / 2.0)) if p < 1.0 else 0.0,
        "z_sign": 0 if p >= 1.0 else (1 if shift > 0 else -1),
        "rank_significant": bool(p < 0.05 and abs(delta) >= NOISE_THRESHOLD_PCT),
        "welch_significant": bool(abs(welch.statistic) >= t_crit and abs(delta) >= NOISE_THRESHOLD_PCT),
    }


CLASSES = ["O_Log_N", "O_N", "O_N_Log_N", "O_N2", "O_N3"]


def curve(cls, n):
    n = np.asarray(n, dtype=float)
    safe = np.maximum(n, 2.0)
    return {
        "O_1": np.ones_like(n),
        "O_Log_N": np.log2(safe),
        "O_N": n,
        "O_N_Log_N": n * np.log2(safe),
        "O_N2": n * n,
        "O_N3": n * n * n,
    }[cls]


def fit_complexity(params, times):
    """Returns the expected estimate, or None when a decision is too close to call."""
    t = np.asarray(times, dtype=float)
    m = len(t)
    mean_t = t.mean()
    ss_tot = float(np.sum((t - mean_t) ** 2))
    if ss_tot == 0:
        return None
    const_nrmse = math.sqrt(ss_tot / m) / mean_t
    best = {
        "class": "O_1",
        "coefficient": float(mean_t),
        "intercept": 0.0,
        "nrmse": const_nrmse,
        "r_squared": min(max(1.0 - const_nrmse**2, 0.0), 1.0),
    }
    f_crit = stats.f.ppf(0.95, 1, m - 2)
    best_nrmse = math.inf
    for cls in CLASSES:
        f = curve(cls, params)
        (c, a), *_ = np.linalg.lstsq(np.column_stack([f, np.ones(m)]), t, rcond=None)
        if abs(c) < MARGIN * mean_t / np.ptp(f):
            return None
        if c <= 0:
            continue
        if abs(a) < MARGIN * mean_t:
            return None
        if a < 0:
            (c,), *_ = np.linalg.lstsq(f[:, None], t, rcond=None)
            a = 0.0
        ss_res = float(np.sum((t - (a + c * f)) ** 2))
        if abs(ss_res / ss_tot - 1.0) < MARGIN:
            return None
        if ss_res >= ss_tot:
            continue
        if ss_res > 0:
            f_stat = (ss_tot - ss_res) * (m - 2) / ss_res
            if abs(f_stat / f_crit - 1.0) < MARGIN:
                return None
            if f_stat <= f_crit:
                continue
        nrmse = math.sqrt(ss_res / m) / mean_t
        if best_nrmse < math.inf and abs(nrmse + 0.005 - best_nrmse) < MARGIN:
            return None
        if nrmse + 0.005 < best_nrmse:
            best_nrmse = nrmse
            best = {
                "class": cls,
                "coefficient": float(c),
                "intercept": float(a),
                "nrmse": nrmse,
                "r_squared": min(max(1.0 - ss_res / ss_tot, 0.0), 1.0),
            }
    return best


def main():
    t_dfs = [1, 1.25, 1.5, 2, 2.5, 3, 4, 5, 7, 10, 15, 20, 30, 50, 100, 1000, 1e6]
    t_quantiles = [{"df": float(df), "t": float(stats.t.ppf(0.975, df))} for df in t_dfs]

    kinds = ["normal", "lognormal", "outliers", "ticks", "integers"]
    sizes = [2, 3, 5, 10, 17, 30, 50, 100, 200]
    samples = []
    for kind in kinds + ["constant"]:
        for n in sizes:
            samples.append(sample_entry(draw(kind, n, 100.0)))

    pairs = []
    shifts = [1.0, 1.01, 1.03, 1.1, 1.5, 0.9]
    pair_sizes = [2, 3, 5, 10, 17, 30, 50]
    attempt = 0
    while len(pairs) < 120:
        kind = kinds[attempt % len(kinds)]
        shift = shifts[(attempt // len(kinds)) % len(shifts)]
        attempt += 1
        n_a = int(rng.choice(pair_sizes))
        n_b = int(rng.choice(pair_sizes))
        a = draw(kind, n_a, 100.0 * shift)
        b = draw(kind, n_b, 100.0)
        entry = pair_entry(a, b)
        if entry is None:
            continue
        entry["a"] = len(samples)
        entry["b"] = len(samples) + 1
        samples.append(sample_entry(a))
        samples.append(sample_entry(b))
        pairs.append(entry)

    param_sets = [
        [8, 64, 512, 4096, 32768],
        [16, 64, 256, 1024, 4096, 16384],
        [10, 20, 40, 80, 160, 320, 640, 1280],
        [100, 1000, 10000],
        [1, 2, 3, 4],
        [32, 128, 512, 2048],
    ]
    complexity = []
    true_classes = ["O_1"] + CLASSES
    attempt = 0
    while len(complexity) < 90:
        i = attempt
        attempt += 1
        params = param_sets[i % len(param_sets)]
        true_cls = true_classes[(i // len(param_sets)) % len(true_classes)]
        fixed = [0.0, 50.0, 1000.0][i % 3]
        noise = [0.0, 0.01, 0.05, 0.2][(i // 3) % 4]
        f = curve(true_cls, params)
        # Scale the growing part so the largest N costs about 10 us on top of the fixed cost.
        c = 10_000.0 / f.max()
        times = (fixed + c * f) * np.exp(rng.normal(0.0, noise, len(params)))
        times = [float(x) for x in times]
        est = fit_complexity(params, times)
        if est is None:
            continue
        complexity.append({"params": params, "times": times, "true_class": true_cls, **est})

    geomean_values = [float(x) for x in draw("lognormal", 40, 1000.0)]
    doc = {
        "generator": "scripts/scipy_reference.py",
        "seed": SEED,
        "numpy": np.__version__,
        "scipy": scipy.__version__,
        "t_quantiles": t_quantiles,
        "samples": samples,
        "pairs": pairs,
        "complexity": complexity,
        "geomean": {"values": geomean_values, "geomean": float(stats.gmean(geomean_values))},
    }
    name = OUT.relative_to(OUT.parent.parent.parent)
    if "--check" in sys.argv[1:]:
        problems = []
        compare(json.loads(OUT.read_text()), json.loads(json.dumps(doc)), "", problems)
        for p in problems[:20]:
            print(f"{name}{p}", file=sys.stderr)
        if problems:
            sys.exit(f"{name} is out of date ({len(problems)} differences); run `make reference`")
        print(f"{name} is up to date")
        return
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(doc, separators=(",", ":")) + "\n")
    print(f"wrote {name}: {len(samples)} samples, {len(pairs)} pairs, "
          f"{len(complexity)} complexity cases")


def compare(old, new, path, problems, scale=1.0):
    """Collects the differences between two loaded reference files that rounding can't
    explain: numbers further apart than 1e-9 of their size or 1e-12 of `scale`, and any
    other change.

    Values computed as small differences of large ones, like the intercept of a fit to
    times around 10 us or the NRMSE of an exact fit, carry rounding noise of the size of
    the data rather than of the value, and that noise differs with the platform's math
    library. A complexity case therefore uses its largest time as the scale.
    """
    if isinstance(old, dict) and isinstance(new, dict):
        if "times" in old:
            scale = max(old["times"])
        for key in sorted(old.keys() | new.keys()):
            if key not in old or key not in new:
                problems.append(f"{path}.{key}: only in one file")
            else:
                compare(old[key], new[key], f"{path}.{key}", problems, scale)
    elif isinstance(old, list) and isinstance(new, list):
        if len(old) != len(new):
            problems.append(f"{path}: {len(old)} entries, now {len(new)}")
        for i, (o, n) in enumerate(zip(old, new)):
            compare(o, n, f"{path}[{i}]", problems, scale)
    elif isinstance(old, float) or isinstance(new, float):
        numbers = isinstance(old, (int, float)) and isinstance(new, (int, float))
        if not numbers or abs(old - new) > max(1e-9 * max(abs(old), abs(new)), 1e-12 * scale):
            problems.append(f"{path}: {old!r}, now {new!r}")
    elif old != new or type(old) is not type(new):
        problems.append(f"{path}: {old!r}, now {new!r}")


if __name__ == "__main__":
    main()
