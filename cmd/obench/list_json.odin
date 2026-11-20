package main

import obench "../../obench"
import "core:encoding/json"
import "core:os"
import "core:path/filepath"

@(private = "file")
_List_Bench :: struct {
	group:      string `json:"group"`,
	name:       string `json:"name"`,
	// Every name the benchmark runs under, one per parameter and thread count, as `--exact`
	// takes them.
	full_names: []string `json:"full_names"`,
	params:     []int `json:"params"`,
	threads:    []int `json:"threads"`,
	zero_alloc: bool `json:"zero_alloc"`,
}

@(private = "file")
_List_Package :: struct {
	name:       string `json:"package"`,
	dir:        string `json:"dir"`,
	// A package with its own main registers its benchmarks there, so they aren't listed.
	has_main:   bool `json:"has_main"`,
	benchmarks: []_List_Bench `json:"benchmarks"`,
}

/*
Prints the discovered packages and their benchmarks as a JSON array, for scripts (`obench list
--json`). Paths are relative to the working directory, as in `list_packages`.
*/
list_packages_json :: proc(packages: []Discovered_Package) {
	cwd, _ := os.get_working_directory(context.temp_allocator)
	out := make([]_List_Package, len(packages), context.temp_allocator)
	for &pkg, i in packages {
		shown, rel_err := filepath.rel(cwd, pkg.dir_path, context.temp_allocator)
		if rel_err != nil {
			shown = pkg.dir_path
		}
		out[i] = {
			name     = pkg.pkg_name,
			dir      = shown,
			has_main = pkg.has_main,
		}
		if pkg.has_main {
			out[i].benchmarks = {}
			continue
		}
		benches := make([]_List_Bench, len(pkg.benches), context.temp_allocator)
		for &b, j in pkg.benches {
			names := make([dynamic]string, context.temp_allocator)
			params := b.params[:] if len(b.params) > 0 else []int{0}
			threads := b.threads[:] if len(b.threads) > 0 else []int{1}
			for p in params {
				for t in threads {
					append(
						&names,
						obench.format_full_name(
							b.group_name,
							b.bench_name,
							p,
							len(b.params) > 0,
							t,
							len(b.threads) > 0,
							context.temp_allocator,
						),
					)
				}
			}
			benches[j] = {
				group      = b.group_name,
				name       = b.bench_name,
				full_names = names[:],
				params     = b.params[:],
				threads    = b.threads[:],
				zero_alloc = b.zero_alloc,
			}
		}
		out[i].benchmarks = benches
	}
	data, err := json.marshal(out, {pretty = true}, context.temp_allocator)
	if err != nil {
		return
	}
	_, _ = os.write(os.stdout, data)
	_, _ = os.write_string(os.stdout, "\n")
}
