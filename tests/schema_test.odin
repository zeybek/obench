package obench_tests

import obench "../obench"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_the_schema_matches_the_report_format :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	file := fmt.tprintf("obench-report-v%d.json", obench.REPORT_FORMAT_VERSION)
	testing.expectf(
		t,
		strings.has_suffix(obench.REPORT_SCHEMA_URL, file),
		"REPORT_SCHEMA_URL %q should end in %q",
		obench.REPORT_SCHEMA_URL,
		file,
	)

	data, err := os.read_entire_file(fmt.tprintf("schema/%s", file), context.temp_allocator)
	if !testing.expectf(t, err == nil, "schema/%s should exist (%v)", file, err) {
		return
	}
	value, parse_err := json.parse(data, allocator = context.temp_allocator)
	if !testing.expect_value(t, parse_err, nil) {
		return
	}
	schema := value.(json.Object)
	testing.expect_value(t, schema["$id"].(json.String), obench.REPORT_SCHEMA_URL)
	format := schema["properties"].(json.Object)["format_version"].(json.Object)
	testing.expect_value(t, format["const"].(json.Float), f64(obench.REPORT_FORMAT_VERSION))
}

@(test)
test_reports_name_their_schema :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	s := obench.suite_create("schema_url", obench.Config{sample_count = 3, fixed_batch_size = 4})
	defer obench.suite_destroy(&s)
	testing.expect_value(
		t,
		obench.export_document(&s, context.temp_allocator).schema,
		obench.REPORT_SCHEMA_URL,
	)
}
