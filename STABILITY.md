# Stability

obench is before 1.0. This page says what counts as its public surface and how that surface changes.

## The public surface

These are what you can build on, and what a release has to call out when it changes them:

- the exported declarations of the `obench` package: every procedure, type, constant and field whose name doesn't start with `_` and that isn't marked `@(private)`
- the CLI's subcommands, flags and exit statuses (0 success, 1 a failed benchmark, regression or build, 2 a usage error, 3 a baseline that can't be compared with the run)
- the `OBENCH_*` environment variables and the `#config(OBENCH_*)` defaults
- the benchmark conventions: `bench_<name>` and `bench_<group>__<name>` procedures, and the `@group`, `@params`, `@threads` and `@zero_alloc` annotations
- the JSON report: its fields and `format_version`, and the CSV report's columns

The terminal table, the Markdown report, the warnings and the runner the CLI generates are for people, and they can change in any release.

## How it changes before 1.0

A release with a breaking change bumps the minor version, so 0.3 goes to 0.4, the way Cargo treats `0.y` versions. Its commit title has a `!` (`feat!:` or `fix!:`), and the release notes list it under BREAKING CHANGES. A release with new features also bumps the minor version, and a release with only fixes bumps the patch version.

Before something public is removed or renamed, it stays for one minor release marked `@(deprecated)` with a note on what to use instead, so code that uses it keeps building with a warning.

## The JSON report

`format_version` goes up whenever the layout changes. A field can be added to a format version only when old readers can ignore it, and readers should ignore fields they don't know. Odin's JSON reader already does. Removing a field, renaming it or changing what it means bumps `format_version` and counts as a breaking change. obench reads reports of every older format version: missing fields stay zero, and a baseline it can't compare fairly fails the regression gate with a warning and exit status 3.

## After 1.0

Breaking changes go into major versions only, as in [SemVer](https://semver.org/).
