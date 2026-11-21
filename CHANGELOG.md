# Changelog

## [0.5.0](https://github.com/zeybek/obench/compare/v0.4.0...v0.5.0) (2026-11-21)


### ⚠ BREAKING CHANGES

* refuse the flags --instructions can't honor ([#116](https://github.com/zeybek/obench/issues/116))
* name the stable part of the package in STABILITY.md ([#118](https://github.com/zeybek/obench/issues/118))
* decide nothing when a side has too few processes for a 95% interval ([#111](https://github.com/zeybek/obench/issues/111))

### Features

* warn when only one side of a comparison comes from several processes ([#117](https://github.com/zeybek/obench/issues/117)) ([7f4fed4](https://github.com/zeybek/obench/commit/7f4fed47451b07046b1749f7aaddaafa17bd02db))


### Bug Fixes

* calibrate the clock after each warmup, with the median of the block means ([#114](https://github.com/zeybek/obench/issues/114)) ([9c56e67](https://github.com/zeybek/obench/commit/9c56e679b554f78cdc4c74a785fe0fec6ee91ef3))
* calibrate the empty loop whatever --batch-size says ([#113](https://github.com/zeybek/obench/issues/113)) ([3680363](https://github.com/zeybek/obench/commit/36803639742b25b810094cd9544b8177037dde2a))
* decide nothing when a side has too few processes for a 95% interval ([#111](https://github.com/zeybek/obench/issues/111)) ([7b853b4](https://github.com/zeybek/obench/commit/7b853b43c4671d285836d7904aa5afba303fca9c))
* keep the process medians of a loaded baseline in the caller's allocator ([#108](https://github.com/zeybek/obench/issues/108)) ([ebd7395](https://github.com/zeybek/obench/commit/ebd7395f61d0e86f46b2baae40bb7fe52901180a))
* leave samples_batch_ns out of a combined report when its processes used different batch sizes ([#109](https://github.com/zeybek/obench/issues/109)) ([9355447](https://github.com/zeybek/obench/commit/93554471e8ae8d3905dc2354fd1bd29e162cf787))
* name a lower Big-O class that fits the same points ([#110](https://github.com/zeybek/obench/issues/110)) ([a7204d2](https://github.com/zeybek/obench/commit/a7204d213dd6769bede2b99e137e32ef77e328ed))
* refuse the flags --instructions can't honor ([#116](https://github.com/zeybek/obench/issues/116)) ([9b7d81b](https://github.com/zeybek/obench/commit/9b7d81b8f0d8de9395e05392a680a1a884d42c13))
* take the faster of two loops as the empty-loop floor ([#115](https://github.com/zeybek/obench/issues/115)) ([6e571eb](https://github.com/zeybek/obench/commit/6e571ebc7c5ec1bf6d7b1efa95c0e9a6e350cf0a))
* write bytes_per_second in bytes in the gbench export ([#106](https://github.com/zeybek/obench/issues/106)) ([dbcfbc0](https://github.com/zeybek/obench/commit/dbcfbc0371657cb433526d98e528990f61e725a5))


### Documentation

* name the stable part of the package in STABILITY.md ([#118](https://github.com/zeybek/obench/issues/118)) ([b834202](https://github.com/zeybek/obench/commit/b834202a8aaa698131982f4bd01cef9637b351bd))

## [0.4.0](https://github.com/zeybek/obench/compare/v0.3.0...v0.4.0) (2026-11-20)


### ⚠ BREAKING CHANGES

* exit with status 3 when the baseline can't be compared ([#74](https://github.com/zeybek/obench/issues/74))
* decide regressions on the confidence interval of the change ([#72](https://github.com/zeybek/obench/issues/72))

### Features

* add --fail-on-alloc-regression ([#61](https://github.com/zeybek/obench/issues/61)) ([bece714](https://github.com/zeybek/obench/commit/bece71423a860e2b63a78978a840e04c4403fd3f))
* add --test, a run-time budget, regex filters, --skip, --exact, list --json and -q ([#75](https://github.com/zeybek/obench/issues/75)) ([fd0f5fe](https://github.com/zeybek/obench/commit/fd0f5fe0dc4a3f5a239099e9aa5c75dad56d4263))
* add a self-contained HTML report ([#77](https://github.com/zeybek/obench/issues/77)) ([688748c](https://github.com/zeybek/obench/commit/688748c62b2f831acf1a1663f8c925e7119b170d))
* add obench export for Bencher, github-action-benchmark and Google Benchmark ([#65](https://github.com/zeybek/obench/issues/65)) ([296d0b1](https://github.com/zeybek/obench/commit/296d0b12c900976fe43ef5087d4c705a539716ad))
* compare several reports per side and alternate two trees with obench ab ([#83](https://github.com/zeybek/obench/issues/83)) ([4c7c56b](https://github.com/zeybek/obench/commit/4c7c56bfda3848a6e03768c3884d07e8a5a0a77e))
* count instructions per operation exactly under Cachegrind with --instructions ([#81](https://github.com/zeybek/obench/issues/81)) ([c3ad2fb](https://github.com/zeybek/obench/commit/c3ad2fb9513d47d332fde7e8587931a668693c7f))
* exit with status 3 when the baseline can't be compared ([#74](https://github.com/zeybek/obench/issues/74)) ([8433230](https://github.com/zeybek/obench/commit/84332302307a0caa94407768747b39eae9d901aa))
* flag correlated, drifting and multimodal samples, an empty-loop floor and an unfit machine ([#79](https://github.com/zeybek/obench/issues/79)) ([38ee897](https://github.com/zeybek/obench/commit/38ee897030e33a674521c959e74d23e5153106f0))
* publish a JSON Schema for reports and check reports against it ([#73](https://github.com/zeybek/obench/issues/73)) ([4d6a2f2](https://github.com/zeybek/obench/commit/4d6a2f28de4a6898e696a11711e5da589d218031))
* read Linux hardware counters per operation with --counters ([#80](https://github.com/zeybek/obench/issues/80)) ([3ed907b](https://github.com/zeybek/obench/commit/3ed907bc1e03d0402ce05a6c6c79e80b426cb405))
* record integer samples_batch_ns in reports ([#21](https://github.com/zeybek/obench/issues/21)) ([158791a](https://github.com/zeybek/obench/commit/158791ac87d0ce215d34317ebed457ee594e8367))
* record the commit, machine, build and run settings in reports ([#69](https://github.com/zeybek/obench/issues/69)) ([20636d8](https://github.com/zeybek/obench/commit/20636d869e633c19a7496fb7c6ed14517e033a02))
* report a run_test failure for each benchmark ([#66](https://github.com/zeybek/obench/issues/66)) ([915065f](https://github.com/zeybek/obench/commit/915065f6384965a972e1588df8a939314aef3570))
* run packages in several processes with --count and compare their medians ([#82](https://github.com/zeybek/obench/issues/82)) ([3aa7dc9](https://github.com/zeybek/obench/commit/3aa7dc9fb1eb4ffc43e66362baa5b1bdeda6ba04))
* warn when the CLI and the vendored library are different versions ([#64](https://github.com/zeybek/obench/issues/64)) ([dc94901](https://github.com/zeybek/obench/commit/dc949014fbbb1ff070699101fb43e3a0d1def6fd))
* write compare results as Markdown and JSON ([#68](https://github.com/zeybek/obench/issues/68)) ([17c9747](https://github.com/zeybek/obench/commit/17c974726cc9c863a0ef5a4b2882985e08c6347e))


### Bug Fixes

* decide regressions on the confidence interval of the change ([#72](https://github.com/zeybek/obench/issues/72)) ([94f4faf](https://github.com/zeybek/obench/commit/94f4fafbe08cc2f8cd87be2d965fdad0af79a6df))
* exit with status 1, not 3, when the baseline file can't be read ([#89](https://github.com/zeybek/obench/issues/89)) ([577bb6c](https://github.com/zeybek/obench/commit/577bb6c92442a01fa3c006118873df6ed0c3a46f))
* flag samples clamped below the clock overhead ([#60](https://github.com/zeybek/obench/issues/60)) ([2fd315a](https://github.com/zeybek/obench/commit/2fd315a6dbe701962b75da9fc890ec9101d5cbdd))
* keep one stalled probe from deciding the batch size ([#71](https://github.com/zeybek/obench/issues/71)) ([d2ba1a8](https://github.com/zeybek/obench/commit/d2ba1a8678ec8e0785d71d67955e075eb06a5171))
* turn colors off outside a terminal and honor NO_COLOR in compare ([#59](https://github.com/zeybek/obench/issues/59)) ([8a71e42](https://github.com/zeybek/obench/commit/8a71e42122899602a7ff47a988c13a2cc4d13a91))

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
