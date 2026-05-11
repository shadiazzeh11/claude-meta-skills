HOOKS := edit-drift-detector construction-gate silent-file-verifier completion-verifier context-recovery

.PHONY: test test-stop-env test-installer test-analyzer test-plugin test-marketplace test-release test-validation-lock test-validation-harness test-repo-hygiene report-dogfood test-% clean install uninstall help

help:
	@echo "claude-meta-skills make targets:"
	@echo "  make test            - run validation harness for all 5 hooks"
	@echo "  make test-stop-env   - run validation harness with CLAUDE_PROJECT_DIR set (simulates Stop-hook env)"
	@echo "  make test-installer  - run installer lifecycle tests (does not invoke hooks)"
	@echo "  make test-analyzer   - run analyzer regression test (uses temp JSONL log; does not touch ~/.claude)"
	@echo "  make test-plugin     - validate plugin manifest/hooks scaffold"
	@echo "  make test-marketplace - validate marketplace catalog and isolated CLI install path"
	@echo "  make test-release VERSION=vX.Y.Z - validate release metadata/version alignment"
	@echo "  make test-validation-lock - verify validation harness lock behavior"
	@echo "  make test-validation-harness - verify validation harness failure reporting"
	@echo "  make test-repo-hygiene - verify cleanup targets preserve tracked placeholders"
	@echo "  make report-dogfood  - write redacted real-dogfood reports to .context/reports/"
	@echo "  make test-<hook>     - run validation harness for one hook"
	@echo "                         (e.g., make test-edit-drift-detector)"
	@echo "  make clean           - remove validation/results/"
	@echo "  make install TARGET=<path>  - install hooks into <path>"
	@echo "                                (use INSTALL_FLAGS=--with-claude-md for CLAUDE.md)"
	@echo "  make uninstall TARGET=<path> - remove meta-skills hooks from <path>"

test:
	@cd validation && fail=0; failed_hooks=""; for h in $(HOOKS); do \
		echo "=== $$h ==="; \
		if ! ./harness.sh $$h; then \
			fail=1; \
			failed_hooks="$$failed_hooks $$h"; \
		fi; \
		echo; \
	done; \
	if [ $$fail -ne 0 ]; then \
		echo "FAILED hooks:$$failed_hooks" >&2; \
		exit 1; \
	fi

test-stop-env:
	@CLAUDE_PROJECT_DIR="$$(pwd)" $(MAKE) test

test-installer:
	@bash testing/test-installer-idempotency.sh

test-analyzer:
	@bash testing/test-analyze-log.sh

test-plugin:
	@bash testing/test-plugin-package.sh

test-marketplace:
	@bash testing/test-marketplace-package.sh

test-release:
	@bash testing/test-release-metadata.sh "$(VERSION)"

test-validation-lock:
	@bash testing/test-validation-lock.sh

test-validation-harness:
	@bash testing/test-validation-harness.sh

test-repo-hygiene:
	@bash testing/test-repo-hygiene.sh

report-dogfood:
	@mkdir -p .context/reports
	@./testing/analyze-log.py --real-only --redact --format markdown --output .context/reports/dogfood-report.md
	@./testing/analyze-log.py --real-only --redact --format json --output .context/reports/dogfood-report.json
	@echo "Wrote .context/reports/dogfood-report.md"
	@echo "Wrote .context/reports/dogfood-report.json"

test-%:
	@cd validation && ./harness.sh $*

clean:
	mkdir -p validation/results
	find validation/results -type f ! -name '.gitkeep' -delete
	touch validation/results/.gitkeep

install:
	@if [ -z "$(TARGET)" ]; then \
		echo "Error: TARGET=<path> required" >&2; \
		echo "Example: make install TARGET=/path/to/project" >&2; \
		echo "         make install TARGET=/path/to/project INSTALL_FLAGS=--with-claude-md" >&2; \
		exit 1; \
	fi
	./install.sh "$(TARGET)" $(INSTALL_FLAGS)

uninstall:
	@if [ -z "$(TARGET)" ]; then \
		echo "Error: TARGET=<path> required" >&2; \
		echo "Example: make uninstall TARGET=/path/to/project" >&2; \
		exit 1; \
	fi
	./install.sh "$(TARGET)" --uninstall
