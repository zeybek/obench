package obench

import "base:runtime"
import "core:prof/spall"

// Size of the in-memory Spall event buffer; it is flushed to the trace file when full.
SPALL_BUFFER_SIZE :: 256 * 1024

/*
Wraps a `core:prof/spall` context and trace buffer for recording benchmark execution spans.
*/
Spall_Recorder :: struct {
	// Don't copy a recorder once it's open: the copy would share the trace buffer.
	enabled:   bool,
	ctx:       spall.Context,
	buffer:    spall.Buffer,
	raw_bytes: []u8,
	allocator: runtime.Allocator,
}

/*
Initializes a Spall trace file at `path`. If `path` is empty, returns a disabled recorder.
*/
@(require_results)
spall_recorder_init :: proc(
	r: ^Spall_Recorder,
	path: string,
	allocator := context.allocator,
) -> bool {
	r^ = Spall_Recorder {
		allocator = allocator,
	}
	if path == "" {
		return true
	}

	ctx, ctx_ok := spall.context_create_with_scale(path, false, 1.0)
	if !ctx_ok {
		return false
	}

	raw_buf, alloc_err := make([]u8, SPALL_BUFFER_SIZE, allocator)
	if alloc_err != nil {
		spall.context_destroy(&ctx)
		return false
	}

	buf, buf_ok := spall.buffer_create(raw_buf, 0, 0)
	if !buf_ok {
		delete(raw_buf, allocator)
		spall.context_destroy(&ctx)
		return false
	}

	r.enabled = true
	r.ctx = ctx
	r.buffer = buf
	r.raw_bytes = raw_buf
	spall._buffer_name_process(&r.ctx, &r.buffer, "obench")
	spall._buffer_name_thread(&r.ctx, &r.buffer, "main")
	return true
}

/*
Flushes and closes the Spall trace file and frees its backing buffer.
*/
spall_recorder_destroy :: proc(r: ^Spall_Recorder) {
	if r == nil || !r.enabled {
		return
	}
	spall.buffer_destroy(&r.ctx, &r.buffer)
	spall.context_destroy(&r.ctx)
	delete(r.raw_bytes, r.allocator)
	r.enabled = false
}

/*
Begins a named span in the Spall trace if recording is enabled.
*/
spall_begin :: #force_inline proc "contextless" (
	r: ^Spall_Recorder,
	name: string,
	args: string = "",
) {
	if r != nil && r.enabled {
		spall._buffer_begin(&r.ctx, &r.buffer, name, args)
	}
}

/*
Ends the active span in the Spall trace if recording is enabled.
*/
spall_end :: #force_inline proc "contextless" (r: ^Spall_Recorder) {
	if r != nil && r.enabled {
		spall._buffer_end(&r.ctx, &r.buffer)
	}
}
