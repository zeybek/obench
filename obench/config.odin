package obench

import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

/*
Configuration for a benchmark suite.

`suite_create` copies every string field, so the strings only need to stay valid until
`suite_create` returns.
*/
Config :: struct {
	warmup_time:          time.Duration, // Default: DEFAULT_WARMUP_MS (40ms)
	min_sample_time:      time.Duration, // Default: DEFAULT_MIN_SAMPLE_US (1ms)
	max_bench_time:       time.Duration, // Default: DEFAULT_MAX_BENCH_MS (1200ms), wall-clock budget for the sampling phase
	sample_count:         int, // Default: DEFAULT_SAMPLES (50)
	fixed_batch_size:     int, // 0 = auto-calibrate
	reset_temp_per_iter:  bool, // Default: true (frees the benchmark's private temp arena after every sample batch)
	enforce_zero_allocs:  bool, // Fail if heap allocations > 0 inside measured loop
	fail_on_regression:   bool, // Fail suite if any benchmark regresses beyond noise_threshold_pct
	filter:               string, // Substring filter on the full benchmark name
	noise_threshold_pct:  f64, // Default: 2.0%
	color_output:         bool, // Default: DEFAULT_COLOR
	show_histogram:       bool, // Default: DEFAULT_HISTOGRAM
	baseline_load_path:   string,
	// Compare only with baseline entries of this suite's name, even when the baseline holds a
	// single suite (set by the CLI when it runs several packages). Default: false.
	match_baseline_suite: bool,
	baseline_save_path:   string,
	json_export_path:     string,
	md_export_path:       string,
	csv_export_path:      string,
	spall_export_path:    string,
}

/*
Returns the default benchmark configuration, applying `#config(OBENCH_*)` constants,
`OBENCH_*` environment variables, and (outside of `odin test`) command-line flags such as
`--filter` or `--samples`.

String fields read from the environment are allocated with `context.temp_allocator`;
`suite_create` copies them, so they only need to live until then.
*/
@(require_results)
default_config :: proc() -> Config {
	cfg := Config {
		warmup_time         = time.Duration(DEFAULT_WARMUP_MS) * time.Millisecond,
		min_sample_time     = time.Duration(DEFAULT_MIN_SAMPLE_US) * time.Microsecond,
		max_bench_time      = time.Duration(DEFAULT_MAX_BENCH_MS) * time.Millisecond,
		sample_count        = DEFAULT_SAMPLES,
		fixed_batch_size    = 0,
		reset_temp_per_iter = true,
		enforce_zero_allocs = DEFAULT_ZERO_ALLOC,
		fail_on_regression  = false,
		filter              = "",
		noise_threshold_pct = 2.0,
		color_output        = DEFAULT_COLOR,
		show_histogram      = DEFAULT_HISTOGRAM,
		spall_export_path   = DEFAULT_SPALL_PATH,
	}

	if val := os.get_env("OBENCH_FILTER", context.temp_allocator); len(val) > 0 {
		cfg.filter = val
	}
	if val := os.get_env("OBENCH_SAMPLES", context.temp_allocator); len(val) > 0 {
		if n, ok := strconv.parse_int(val); ok && n > 0 {
			cfg.sample_count = n
		}
	}
	if val := os.get_env("OBENCH_WARMUP_MS", context.temp_allocator); len(val) > 0 {
		if n, ok := strconv.parse_int(val); ok && n >= 0 {
			cfg.warmup_time = time.Duration(n) * time.Millisecond
		}
	}
	if val := os.get_env("OBENCH_ZERO_ALLOC", context.temp_allocator);
	   val == "1" || val == "true" {
		cfg.enforce_zero_allocs = true
	}
	if val := os.get_env("OBENCH_FAIL_ON_REGRESSION", context.temp_allocator);
	   val == "1" || val == "true" {
		cfg.fail_on_regression = true
	}
	if val := os.get_env("OBENCH_THRESHOLD", context.temp_allocator); len(val) > 0 {
		if f, ok := strconv.parse_f64(val); ok && f > 0 {
			cfg.noise_threshold_pct = f
		}
	}
	if val := os.get_env("OBENCH_NO_COLOR", context.temp_allocator); val == "1" || val == "true" {
		cfg.color_output = false
	}
	if val := os.get_env("NO_COLOR", context.temp_allocator); len(val) > 0 {
		// https://no-color.org
		cfg.color_output = false
	}
	if val := os.get_env("OBENCH_BASELINE", context.temp_allocator); len(val) > 0 {
		cfg.baseline_load_path = val
	}
	if val := os.get_env("OBENCH_SAVE_BASELINE", context.temp_allocator); len(val) > 0 {
		cfg.baseline_save_path = val
	}
	if val := os.get_env("OBENCH_JSON", context.temp_allocator); len(val) > 0 {
		cfg.json_export_path = val
	}
	if val := os.get_env("OBENCH_MD", context.temp_allocator); len(val) > 0 {
		cfg.md_export_path = val
	}
	if val := os.get_env("OBENCH_CSV", context.temp_allocator); len(val) > 0 {
		cfg.csv_export_path = val
	}
	if val := os.get_env("OBENCH_SPALL", context.temp_allocator); len(val) > 0 {
		cfg.spall_export_path = val
	}

	when !ODIN_TEST {
		apply_args(&cfg, os.args[1:] if len(os.args) > 0 else nil)
	}

	return cfg
}

/*
Applies obench command-line flags (`--filter`, `--samples`, `--warmup`, `--threshold`,
`--baseline`, `--match-baseline-suite`, `--save-baseline`, `--json`, `--md`, `--csv`,
`--spall`, `--zero-alloc`, `--fail-on-regression`, `--no-color`, `--no-histogram`) to `cfg`.

Values may be given as `--flag value`, `--flag=value`, or `-flag:value`. Unknown arguments
are ignored so programs can mix obench flags with their own. String values point into
`args`.
*/
apply_args :: proc(cfg: ^Config, args: []string) {
	i := 0
	for i < len(args) {
		arg := args[i]
		i += 1
		if !strings.has_prefix(arg, "-") {
			continue
		}
		switch arg {
		case "--zero-alloc", "-zero-alloc":
			cfg.enforce_zero_allocs = true
			continue
		case "--fail-on-regression", "-fail-on-regression":
			cfg.fail_on_regression = true
			continue
		case "--no-color", "-no-color":
			cfg.color_output = false
			continue
		case "--no-histogram", "-no-histogram":
			cfg.show_histogram = false
			continue
		case "--match-baseline-suite", "-match-baseline-suite":
			cfg.match_baseline_suite = true
			continue
		}

		trimmed := strings.trim_left(arg, "-")
		key := trimmed
		val := ""
		has_inline := false
		if sep := strings.index_any(trimmed, "=:"); sep >= 0 {
			key = trimmed[:sep]
			val = trimmed[sep + 1:]
			has_inline = true
		}

		switch key {
		case "f",
		     "filter",
		     "n",
		     "samples",
		     "w",
		     "warmup",
		     "threshold",
		     "save-baseline",
		     "baseline",
		     "json",
		     "md",
		     "csv",
		     "spall":
		case:
			continue // Not an obench flag.
		}
		if !has_inline {
			if i >= len(args) {
				break
			}
			val = args[i]
			i += 1
		}

		switch key {
		case "f", "filter":
			cfg.filter = val
		case "n", "samples":
			if n, ok := strconv.parse_int(val); ok && n > 0 {
				cfg.sample_count = n
			}
		case "w", "warmup":
			if n, ok := strconv.parse_int(val); ok && n >= 0 {
				cfg.warmup_time = time.Duration(n) * time.Millisecond
			}
		case "threshold":
			if f, ok := strconv.parse_f64(val); ok && f > 0 {
				cfg.noise_threshold_pct = f
			}
		case "save-baseline":
			cfg.baseline_save_path = val
		case "baseline":
			cfg.baseline_load_path = val
		case "json":
			cfg.json_export_path = val
		case "md":
			cfg.md_export_path = val
		case "csv":
			cfg.csv_export_path = val
		case "spall":
			cfg.spall_export_path = val
		}
	}
}
