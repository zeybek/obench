package main

import obench "../../obench"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_library_dir_resolves_relative_and_collection_imports :: proc(t: ^testing.T) {
	root := filepath.is_abs("/p") ? "/p" : "C:/p"
	pkg_dir, _ := filepath.join({root, "bench"}, context.temp_allocator)
	libs, _ := filepath.join({root, "vendor", "libs"}, context.temp_allocator)
	collections := []string {
		"other=/elsewhere",
		strings.concatenate({"libs=", libs}, context.temp_allocator),
	}

	dir, ok := library_dir("../libs/obench", pkg_dir, collections)
	want, _ := filepath.join({root, "libs", "obench"}, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, dir, want)

	dir, ok = library_dir("libs:obench", pkg_dir, collections)
	want, _ = filepath.join({libs, "obench"}, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, dir, want)

	_, ok = library_dir("shared:obench", pkg_dir, collections)
	testing.expect(t, !ok, "a collection that wasn't passed can't be resolved")
	_, ok = library_dir("", pkg_dir, collections)
	testing.expect(t, !ok, "no import, no directory")
}

@(test)
test_library_version_reads_the_version_constant :: proc(t: ^testing.T) {
	// The repository's own library is the version this CLI was built with.
	version, ok := library_version("obench")
	testing.expect(t, ok)
	testing.expect_value(t, version, obench.VERSION)

	dir := ".obench_test_library_version"
	testing.expect_value(t, os.make_directory(dir), nil)
	defer _ = os.remove_all(dir)
	_, ok = library_version(dir)
	testing.expect(t, !ok, "no doc.odin")

	doc, _ := filepath.join({dir, "doc.odin"}, context.temp_allocator)
	testing.expect_value(
		t,
		os.write_entire_file(
			doc,
			"package obench\n\nVERSION :: \"0.1.0\" // x-release-please-version\n",
		),
		nil,
	)
	version, ok = library_version(dir)
	testing.expect(t, ok)
	testing.expect_value(t, version, "0.1.0")
}
