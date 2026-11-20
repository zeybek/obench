package main

import obench "../../obench"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Library directories already checked, so each mismatch is reported once per run.
@(private = "file")
g_checked_library_dirs: map[string]bool

/*
Returns the directory of the obench library that `lib_import`, the import path a benchmark
package uses for obench, points at. A relative path is taken from `pkg_dir`, and a
collection import such as `libs:obench` is looked up in `collections`, entries of the form
`name=path` from `--collection` and `--ols`. `ok` is false when the collection is unknown.
*/
@(private)
library_dir :: proc(
	lib_import: string,
	pkg_dir: string,
	collections: []string,
	allocator := context.temp_allocator,
) -> (
	dir: string,
	ok: bool,
) {
	if lib_import == "" {
		return
	}
	if colon := strings.index_byte(lib_import, ':'); colon > 0 && !filepath.is_abs(lib_import) {
		name, sub := lib_import[:colon], lib_import[colon + 1:]
		for col in collections {
			eq := strings.index_byte(col, '=')
			if eq > 0 && col[:eq] == name {
				dir, _ = filepath.join({col[eq + 1:], sub}, allocator)
				return dir, true
			}
		}
		return
	}
	if filepath.is_abs(lib_import) {
		return lib_import, true
	}
	dir, _ = filepath.join({pkg_dir, lib_import}, allocator)
	return dir, true
}

/*
Reads the version of the obench library in `dir` from the `VERSION` constant in its
`doc.odin`. `ok` is false when the file or the constant isn't there.
*/
@(private)
library_version :: proc(
	dir: string,
	allocator := context.temp_allocator,
) -> (
	version: string,
	ok: bool,
) {
	path, _ := filepath.join({dir, "doc.odin"}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return
	}
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		rest := strings.trim_left_space(line)
		if !strings.has_prefix(rest, "VERSION ::") {
			continue
		}
		start := strings.index_byte(rest, '"')
		if start < 0 {
			return
		}
		end := strings.index_byte(rest[start + 1:], '"')
		if end < 0 {
			return
		}
		return strings.clone(rest[start + 1:][:end], allocator), true
	}
	return
}

/*
Warns once per library directory when the obench library a package builds against is
another version than the one this CLI was built with. The generated runner calls the
library's API, so a mismatch can make it fail to build or behave differently, with an
error that says nothing about versions.
*/
@(private)
warn_on_library_version_mismatch :: proc(lib_import, pkg_dir: string, collections: []string) {
	dir, ok := library_dir(lib_import, pkg_dir, collections)
	if !ok {
		return
	}
	if abs, abs_err := filepath.abs(dir, context.temp_allocator); abs_err == nil {
		dir = abs
	}
	if dir in g_checked_library_dirs {
		return
	}
	g_checked_library_dirs[strings.clone(dir)] = true
	version, found := library_version(dir)
	if found && version != obench.VERSION {
		fmt.eprintfln(
			"obench: warning: this CLI is %s but the obench library in '%s' is %s; use the same version of both",
			obench.VERSION,
			dir,
			version,
		)
	}
}
