# Changelog

## [0.3.0](https://github.com/zeybek/obench/compare/v0.2.1...v0.3.0) (2026-11-18)


### ⚠ BREAKING CHANGES

* count allocations outside the timed samples by default ([#20](https://github.com/zeybek/obench/issues/20))

### Features

* add silent suite_execute API and preserve custom_metrics in baselines ([#17](https://github.com/zeybek/obench/issues/17)) ([f6e8243](https://github.com/zeybek/obench/commit/f6e82438d695c9cafd6bb58aec280b8d4b4b9f15))
* add untimed allocation counting option (--untimed-allocs) ([#15](https://github.com/zeybek/obench/issues/15)) ([3387a08](https://github.com/zeybek/obench/commit/3387a0848b79aff52436ccbd02855d89e843cc70))
* **cli:** add --extra-linker-flags, --custom-attribute, and --ols ([#16](https://github.com/zeybek/obench/issues/16)) ([3f199a8](https://github.com/zeybek/obench/commit/3f199a80a1b07dfbc80ee5640e03cdbae7aa3fdf))


### Bug Fixes

* count allocations outside the timed samples by default ([#20](https://github.com/zeybek/obench/issues/20)) ([74bc973](https://github.com/zeybek/obench/commit/74bc973a387b966c95c4903c6110af9e7f39ed48))


### Performance Improvements

* use libc vDSO clock_gettime on Linux ([#14](https://github.com/zeybek/obench/issues/14)) ([5a25b0d](https://github.com/zeybek/obench/commit/5a25b0d4864a39345d02451d56a05ff6f5e4ad9d))

## [0.2.1](https://github.com/zeybek/obench/compare/v0.2.0...v0.2.1) (2026-11-15)


### Bug Fixes

* **cli:** fail the run when the compiler builds nothing ([#9](https://github.com/zeybek/obench/issues/9)) ([a13f222](https://github.com/zeybek/obench/commit/a13f222a03ccf9b54d1bc2711ae42ee1f5b70d9a))
* **cli:** skip #+test files during discovery ([#11](https://github.com/zeybek/obench/issues/11)) ([41425ff](https://github.com/zeybek/obench/commit/41425ff55f4f24d67df2dde161aab44a8f878c19))
* fail the gate on a baseline from another build ([#10](https://github.com/zeybek/obench/issues/10)) ([d41e38b](https://github.com/zeybek/obench/commit/d41e38bc8e67c2af44a23efbeb56fbe5c33c4074))
* measure peak_heap_bytes correctly when benchmarks use free ([#13](https://github.com/zeybek/obench/issues/13)) ([8f2dd6e](https://github.com/zeybek/obench/commit/8f2dd6e8262d3605c2b4650bc3fa8a48c720c92a))

## [0.2.0](https://github.com/zeybek/obench/compare/v0.1.0...v0.2.0) (2026-11-01)


### ⚠ BREAKING CHANGES

* correct measurement, reporting, and CLI discovery issues found in review ([#2](https://github.com/zeybek/obench/issues/2))

### Bug Fixes

* correct measurement, reporting, and CLI discovery issues found in review ([#2](https://github.com/zeybek/obench/issues/2)) ([8f8c3c0](https://github.com/zeybek/obench/commit/8f8c3c0eaa862e49a968df5b67e991c30797f61a))

## 0.1.0 (2026-10-31)


### Features

* micro-benchmarking library and CLI for Odin ([13548c9](https://github.com/zeybek/obench/commit/13548c95da9f8b0a6053ebe7482b1df977ec8216))
