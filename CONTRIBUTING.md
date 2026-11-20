# Contributing to obench

Bug reports, fixes, and new examples are welcome. For anything larger than a fix, open an issue first so we can agree on the shape before you write the code.

## Setup

You need Odin `dev-2026-10` or newer, `make`, and `bash`. The repository is laid out like this:

| Path | What it is |
| :--- | :--- |
| `obench/` | The library package, the only folder users copy into their projects |
| `cmd/obench/` | The CLI, with its tests in `main_test.odin` |
| `tests/` | Library tests, plus `barrier_probe/` for `scripts/check_barriers.sh` and, in `testdata/`, the numpy and scipy values the statistics are checked against |
| `examples/` | Example benchmarks. All but `core_style` are found and run by the CLI |
| `scripts/` | End-to-end checks of the CLI (`smoke.sh`), the checks the git hooks run, the documentation build (`build_docs.sh` with `odin-doc.json`), and the generator of the scipy reference data (`scipy_reference.py`) |

`obench/` is one Odin package with a file per topic. `config.odin`, `bencher.odin`, and `suite.odin` hold what users call; `runner.odin` holds the measuring loop behind `suite_run`. Each report format has its own `report_*.odin`, and the rest (`stats`, `complexity`, `clock`, `allocator`, `batch`, `parallel`, `black_box`, `spall`, `testing`) are named after what they do. Subfolders would be separate packages in Odin, which is why there are none.

The user documentation lives in two places: the README, and the package documentation in `obench/doc.odin`, which `make docs` renders into `build/docs` with the generator behind pkg.odin-lang.org.

Optional tools the repository is set up for:

| Tool | What it does here |
| :--- | :--- |
| [lefthook](https://lefthook.dev) | `make hooks` installs a commit-msg hook that checks the Conventional Commits header and a pre-commit hook that runs odinfmt, `make check`, shellcheck, and typos on what you commit. Hooks for tools you don't have are skipped. |
| [actionlint](https://github.com/rhysd/actionlint), [shellcheck](https://www.shellcheck.net), [typos](https://github.com/crate-ci/typos) | `make lint` runs whichever is installed. CI runs all three. |
| [lychee](https://lychee.cli.rs) | `make links` checks the links in the documentation. CI runs it weekly. |
| [uv](https://docs.astral.sh/uv/) | `make reference` regenerates `tests/testdata/scipy_reference.json` with the numpy and scipy versions pinned in `scripts/scipy_reference.py`. `make reference-check` compares the committed file with a fresh run, as CI does. |

## Before you open a pull request

```sh
make check            # odin check on every package, with the flags Odin's own CI uses for core
make check-barriers   # black_box and keep_alive survive -o:speed and -o:aggressive
make test             # library and CLI tests (leak checks + AddressSanitizer), then examples/core_style
make smoke            # builds bin/obench and runs scripts/smoke.sh
make bench            # runs all examples through the CLI
make fmt-check ODINFMT=path/to/odinfmt
```

If AddressSanitizer isn't available on your platform, run `make test TEST_FLAGS=`.

`tests/scipy_reference_test.odin` checks the percentiles, standard deviation, confidence interval, MAD, outliers, t quantiles, Welch and Mann-Whitney statistics, significance decisions, Big-O fits, and geomean against numpy and scipy. If you change one of them on purpose, update `scripts/scipy_reference.py` to match and run `make reference`.

`odinfmt` comes from [DanielGavin/ols](https://github.com/DanielGavin/ols). Build it with `odin build tools/odinfmt/main.odin -file -collection:src=src -out:odinfmt -o:speed` in a clone of that repository. CI pins the commit it uses in `.github/workflows/ci.yml`, and `make fmt` formats everything with the repository's `odinfmt.json`.

## Code style

Follow the [Odin naming and style convention](https://github.com/odin-lang/examples/wiki/Naming-and-style-convention): `Ada_Case` types and enum values, `snake_case` procedures and variables, `SCREAMING_SNAKE_CASE` constants, and tabs for indentation. On top of that:

- Prefer `core:` packages over hand-written helpers. The reports use `core:text/table` and `core:encoding/csv`, and the CLI uses `core:flags`.
- Procedures that allocate take `allocator` and `loc := #caller_location` parameters. Procedures that return a value people shouldn't ignore get `@(require_results)`.
- File operations return `Report_Error` rather than `bool`.
- Every public declaration needs a doc comment that `odin doc` can render.

## Changes users will see

Don't edit `CHANGELOG.md` or the `VERSION` constant by hand. [release-please](https://github.com/googleapis/release-please) writes both from the commit messages on `main` (see below). What you control is the pull request title, which becomes the commit message: a `feat:` or `fix:` shows up in the release notes, and a `!` after the type (`feat!: ...`) marks a breaking change. A change to the JSON report layout is breaking and also needs `REPORT_FORMAT_VERSION` bumped. A breaking change also adds what users have to do to the next release's section of [docs/migration.md](docs/migration.md).

If you add an example the CLI discovers, add it to `RUNNER_EXAMPLES` in the `Makefile` and to the check step in `.github/workflows/ci.yml`. Also update the package and benchmark counts in `scripts/smoke.sh` and the package count that `test_discover_skips_non_benchmark_packages` in `cmd/obench/main_test.odin` expects from the repository root. That test counts every benchmark package below the root, so an untracked scratch package there makes `make test-cli` fail.

Benchmark numbers in documentation must come from a real run, and the text should name the machine they came from.

## Commit messages and pull requests

Commits follow [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `perf:`, `refactor:`, `docs:`, `style:`, `test:`, `build:`, `ci:`, `chore:` or `revert:`, an optional scope (`fix(cli): ...`), and `!` for breaking changes. The commit-msg hook checks this locally.

Every change to `main` goes through a pull request, the maintainer's own included. Pull requests are squash-merged, so the PR title becomes the commit on `main` and the description stays on the pull request. A workflow checks that the title follows the same format. The pull request template asks for what changed, why, and how you tested it.

## Releases

After CI passes on a push to `main`, release-please opens or updates a release PR. If CI fails, the release PR stays as it was until a later push passes. It picks the next version from the commits since the last release (before 1.0, a breaking change bumps the minor version) and writes the changelog entry. The PR updates `CHANGELOG.md` and `VERSION` in `obench/doc.odin`. Merging it tags the release and creates the GitHub release as a draft. The CLIs for five platforms are built with read-only access and one fixed Odin release, `ODIN_RELEASE` at the top of `.github/workflows/release-please.yml`, which has to be raised by hand. A last job packs them and the `obench` folder with `scripts/package_release.py`, which gives the same archive for the same files, attests where each archive came from, attaches the archives with their SHA-256 sums, and publishes the release. With immutable releases turned on in the repository settings, the assets of a published release can't be replaced.

The CLIs are built by `scripts/build_release_cli.sh`, which links the Linux ones statically, and the release job runs each Linux CLI in a `debian:11` container, whose glibc is older than any runner's. The macOS CLIs are signed with a Developer ID and notarized when the repository has these secrets, and only ad-hoc signed otherwise:

- `APPLE_CERTIFICATE_P12_BASE64` and `APPLE_CERTIFICATE_PASSWORD`: the Developer ID Application certificate, exported as a `.p12` file and base64-encoded, and its password
- `APPLE_SIGNING_IDENTITY`: its name, like `Developer ID Application: Name (TEAMID)`
- `APPLE_ID`, `APPLE_TEAM_ID` and `APPLE_APP_PASSWORD`: the Apple ID, team, and an app-specific password for `notarytool`

The release PR is opened with the default `GITHUB_TOKEN`, and GitHub holds the `pull_request` runs on it until a maintainer approves them on the pull request (they show as "action required"). The release workflow doesn't wait for that: whenever it opens or updates the PR, it starts CI, Lint and Links on the PR's branch with `workflow_dispatch`, and their checks show on the PR. CI leaves out Odin's nightly build there. The held runs don't need approving.
