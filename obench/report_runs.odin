package obench

import "core:math"
import "core:slice"

/*
Combines reports of the same suites from several processes, like those `obench --count`
runs, into one: the report of the first process, with every benchmark's samples pooled in
process order, its statistics computed again over the pooled samples, and the median of
each process kept in `process_medians_ns`, which the regression test compares when both
sides have at least two (see `compare_baseline`). A benchmark that failed in any process
keeps that error. Allocation counts, custom metrics, `batch_size`, and complexity fits come
from the first process that has the benchmark. `samples_batch_ns` is pooled as well when
every process used the same batch size, as with a fixed one, and left out otherwise: each
process calibrates its own batch, and one `batch_size` can't describe batches of several
sizes. A report that already combines processes counts as
that many, with its process medians carried over, so `processes` is the total.

Everything is allocated with `allocator`; the strings still point into `docs`.
*/
@(require_results)
combine_runs :: proc(docs: []Export_Document, allocator := context.allocator) -> Export_Document {
	if len(docs) == 0 {
		return {}
	}
	if len(docs) == 1 {
		return docs[0]
	}
	out := docs[0]
	out.processes = 0
	for doc in docs {
		out.processes += max(doc.processes, 1)
	}

	key :: proc(e: Export_Entry) -> [2]string {
		return {e.suite_name, e.full_name}
	}
	// Every benchmark in the order of first appearance, with its entry from each process.
	order := make([dynamic][2]string, allocator)
	defer delete(order)
	runs := make(map[[2]string][dynamic]Export_Entry, allocator = allocator)
	defer {
		for _, v in runs {
			delete(v)
		}
		delete(runs)
	}
	for doc in docs {
		for e in doc.benchmarks {
			k := key(e)
			if k not_in runs {
				append(&order, k)
				runs[k] = make([dynamic]Export_Entry, allocator)
			}
			append(&runs[k], e)
		}
	}

	entries := make([]Export_Entry, len(order), allocator)
	log_sum: f64 = 0
	log_count := 0
	for k, i in order {
		entries[i] = _combine_entry(runs[k][:], allocator)
		if entries[i].error == "" && entries[i].p50_ns > 0 {
			log_sum += math.ln(entries[i].p50_ns)
			log_count += 1
		}
	}
	out.benchmarks = entries
	out.geomean_ns = math.exp(log_sum / f64(log_count)) if log_count > 0 else 0
	return out
}

@(private = "file")
_combine_entry :: proc(entries: []Export_Entry, allocator := context.allocator) -> Export_Entry {
	first := entries[0]
	out := first
	for e in entries {
		if e.error != "" {
			out.error = e.error
			return out
		}
	}

	pooled := make([dynamic]f64, allocator)
	pooled_batch := make([dynamic]u64, allocator)
	medians := make([dynamic]f64, allocator)
	cycles := make([]f64, len(entries), allocator)
	defer delete(cycles, allocator)
	clamped := 0
	overhead_share: f64 = 0
	same_batch_size := true
	for e, i in entries {
		same_batch_size &&= e.batch_size == first.batch_size
		append(&pooled, ..e.samples_ns)
		append(&pooled_batch, ..e.samples_batch_ns)
		// A report that already combines processes brings their medians along.
		if len(e.process_medians_ns) > 0 {
			append(&medians, ..e.process_medians_ns)
		} else {
			append(&medians, e.p50_ns)
		}
		cycles[i] = e.median_cycles
		clamped += e.clamped_samples
		overhead_share += e.overhead_share
	}
	out.process_medians_ns = medians[:]
	out.samples_ns = pooled[:]
	if same_batch_size {
		out.samples_batch_ns = pooled_batch[:]
	} else {
		delete(pooled_batch)
		out.samples_batch_ns = nil
	}
	out.samples = len(pooled)
	out.clamped_samples = clamped
	out.overhead_share = overhead_share / f64(len(entries))
	slice.sort(cycles)
	out.median_cycles = percentile_sorted(cycles, 0.5)

	if len(pooled) == 0 {
		return out
	}
	st := compute_stats(
		pooled[:],
		pooled[:],
		first.batch_size,
		0,
		0,
		0,
		nil,
		nil,
		allocator = allocator,
	)
	out.min_ns = st.min_ns
	out.p50_ns = st.p50_ns
	out.p95_ns = st.p95_ns
	out.p99_ns = st.p99_ns
	out.max_ns = st.max_ns
	out.mean_ns = st.mean_ns
	out.std_dev_ns = st.std_dev_ns
	out.ci95_ns = st.ci95_ns
	out.mad_ns = st.mad_ns
	out.autocorrelation = st.autocorrelation
	out.effective_samples = st.effective_samples
	out.trend_pct = st.trend_pct
	out.modes = st.modes
	// Throughput is a fixed amount of work divided by the time.
	if first.p50_ns > 0 && out.p50_ns > 0 {
		scale := first.p50_ns / out.p50_ns
		out.mb_per_sec = first.mb_per_sec * scale
		out.items_per_sec = first.items_per_sec * scale
	}
	return out
}
