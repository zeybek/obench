package main

import "core:os"
import "core:strings"

/*
Runs `git` with `args` in `dir` and returns its standard output without the trailing newline.
`ok` is false when `git` isn't installed, `dir` isn't in a repository, or the command fails.
*/
@(private = "file")
_git :: proc(dir: string, args: ..string) -> (out: string, ok: bool) {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "git", "-C", dir)
	append(&cmd, ..args)
	state, stdout, _, err := os.process_exec({command = cmd[:]}, context.temp_allocator)
	if err != nil || !state.exited || state.exit_code != 0 {
		return
	}
	return strings.trim_right_space(string(stdout)), true
}

/*
Sets `OBENCH_GIT_COMMIT`, `OBENCH_GIT_BRANCH`, and `OBENCH_GIT_DIRTY` from the repository that
holds `dir`, so the benchmark runners the CLI starts write the commit into their JSON reports.
Values someone already set are kept, and nothing is set outside a repository.
*/
@(private)
set_git_environment :: proc(dir: string) {
	if os.get_env("OBENCH_GIT_COMMIT", context.temp_allocator) != "" {
		return
	}
	commit, ok := _git(dir, "rev-parse", "HEAD")
	if !ok || commit == "" {
		return
	}
	_ = os.set_env("OBENCH_GIT_COMMIT", commit)
	if branch, branch_ok := _git(dir, "rev-parse", "--abbrev-ref", "HEAD");
	   branch_ok && branch != "HEAD" {
		_ = os.set_env("OBENCH_GIT_BRANCH", branch)
	}
	if status, status_ok := _git(dir, "status", "--porcelain", "--untracked-files=no"); status_ok {
		_ = os.set_env("OBENCH_GIT_DIRTY", "1" if status != "" else "0")
	}
}
