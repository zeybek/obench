<!--
The title becomes the commit message on main, so write it as a Conventional Commit:
fix: ..., feat: ..., perf: ..., docs: ... Put ! after the type (feat!: ...) if the change
breaks existing code or the JSON report layout.
-->

## What and why

<!-- What changed and why. Link the issue if there is one ("Closes #123"). -->

## How it was tested

<!-- The commands you ran, and on which OS and CPU. If the change affects measurements or the
report, paste the obench output from before and after. -->

## Checklist

<!-- Tick what you did. Delete the lines that don't apply. -->

- [ ] `make check test smoke` passes
- [ ] `make fmt-check` passes, or I couldn't run odinfmt and CI will check it
- [ ] Changes to `black_box`, `keep_alive`, or `clobber_memory` pass `make check-barriers`
- [ ] New behavior has a test in `tests/` or `cmd/obench/main_test.odin`
- [ ] New or changed public declarations have doc comments, and `obench/doc.odin` covers anything users need to know
- [ ] A change to the JSON report layout bumps `REPORT_FORMAT_VERSION`
- [ ] A new example the CLI discovers is in `RUNNER_EXAMPLES` in the `Makefile`, in the check step of `.github/workflows/ci.yml`, and in the counts in `scripts/smoke.sh`
- [ ] Benchmark numbers in the docs come from a real run on a named machine
