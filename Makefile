.PHONY: all build check check-barriers docs fmt fmt-check hooks lint links reference reference-check test test-lib test-cli test-examples smoke bench bench-allocators bench-soa bench-lookup bench-sorting bench-parallel clean

ODIN ?= odin
# odinfmt from DanielGavin/ols (tools/odinfmt); see CONTRIBUTING.md.
ODINFMT ?= odinfmt
SOURCES = obench/*.odin cmd/obench/*.odin tests/*.odin tests/barrier_probe/*.odin examples/*/*.odin
# The same checks Odin's own CI applies to core.
FLAGS := -vet -vet-tabs -vet-style -vet-cast -strict-style -warnings-as-errors -disallow-do
# Extra flags for test runs; set TEST_FLAGS= to drop the sanitizer where it isn't available.
TEST_FLAGS ?= -sanitize:address -define:ODIN_TEST_FANCY=false
BIN_DIR := bin
OBENCH_BIN := $(BIN_DIR)/obench
# Example packages without a main procedure (driven by the CLI's generated runner).
RUNNER_EXAMPLES := allocators aos_vs_soa parallel sorting core_style

all: check check-barriers test build smoke

$(OBENCH_BIN): cmd/obench/*.odin obench/*.odin
	@mkdir -p $(BIN_DIR)
	$(ODIN) build cmd/obench -out:$(OBENCH_BIN) -o:speed $(FLAGS)

build: $(OBENCH_BIN)

check:
	$(ODIN) check obench -no-entry-point $(FLAGS)
	$(ODIN) check cmd/obench $(FLAGS)
	$(ODIN) check tests -no-entry-point $(FLAGS)
	$(ODIN) check examples/lookup $(FLAGS)
	@for ex in $(RUNNER_EXAMPLES); do \
		echo "$(ODIN) check examples/$$ex -no-entry-point $(FLAGS)"; \
		$(ODIN) check examples/$$ex -no-entry-point $(FLAGS) || exit 1; \
	done

# black_box/keep_alive must survive -o:speed and -o:aggressive (inspects the assembly).
check-barriers:
	./scripts/check_barriers.sh

# Installs the git hooks from .lefthook.yml (needs lefthook: https://lefthook.dev).
hooks:
	lefthook install

# Workflow files, shell scripts and spelling, with whichever of the tools are installed.
lint:
	@if command -v actionlint >/dev/null; then echo "actionlint"; actionlint; else echo "actionlint not installed, skipped"; fi
	@if command -v shellcheck >/dev/null; then echo "shellcheck"; shellcheck scripts/*.sh; else echo "shellcheck not installed, skipped"; fi
	@if command -v typos >/dev/null; then echo "typos"; typos; else echo "typos not installed, skipped"; fi

# HTML documentation in build/docs (needs odin-doc, see scripts/build_docs.sh).
docs:
	./scripts/build_docs.sh

# Regenerates tests/testdata/scipy_reference.json with the pinned numpy and scipy (needs uv).
reference:
	uv run --quiet scripts/scipy_reference.py

# Fails when tests/testdata/scipy_reference.json differs from a fresh run.
reference-check:
	uv run --quiet scripts/scipy_reference.py --check

# Links in the documentation (needs lychee).
links:
	lychee --no-progress --max-concurrency 8 --timeout 20 './*.md' './scripts/odin-doc.json'

fmt:
	@for f in $(SOURCES); do $(ODINFMT) -config:odinfmt.json -w "$$f" || exit 1; done

fmt-check:
	@status=0; for f in $(SOURCES); do \
		$(ODINFMT) -config:odinfmt.json "$$f" | diff -q "$$f" - >/dev/null || { echo "needs formatting: $$f"; status=1; }; \
	done; exit $$status

test: test-lib test-cli test-examples

test-lib:
	$(ODIN) test tests -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true $(FLAGS) $(TEST_FLAGS)

test-cli:
	$(ODIN) test cmd/obench -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true $(FLAGS) $(TEST_FLAGS)

# Benchmarks that run inside `odin test` (short settings to keep CI fast).
test-examples:
	$(ODIN) test examples/core_style -o:speed -define:OBENCH_SAMPLES=10 -define:OBENCH_WARMUP_MS=5 $(FLAGS)

smoke: $(OBENCH_BIN)
	./scripts/smoke.sh ./$(OBENCH_BIN)

bench: $(OBENCH_BIN)
	./$(OBENCH_BIN) examples

bench-allocators: $(OBENCH_BIN)
	./$(OBENCH_BIN) examples/allocators

bench-soa: $(OBENCH_BIN)
	./$(OBENCH_BIN) examples/aos_vs_soa

bench-lookup: $(OBENCH_BIN)
	./$(OBENCH_BIN) examples/lookup

bench-sorting: $(OBENCH_BIN)
	./$(OBENCH_BIN) examples/sorting

bench-parallel: $(OBENCH_BIN)
	./$(OBENCH_BIN) examples/parallel

clean:
	rm -rf $(BIN_DIR) build .obench_test_*
