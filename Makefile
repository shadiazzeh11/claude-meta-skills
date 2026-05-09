HOOKS := edit-drift-detector construction-gate silent-file-verifier completion-verifier context-recovery

.PHONY: test test-stop-env test-installer test-% clean install help

help:
	@echo "claude-meta-skills make targets:"
	@echo "  make test            - run validation harness for all 5 hooks"
	@echo "  make test-stop-env   - run validation harness with CLAUDE_PROJECT_DIR set (simulates Stop-hook env)"
	@echo "  make test-installer  - run installer idempotency tests (does not invoke hooks)"
	@echo "  make test-<hook>     - run validation harness for one hook"
	@echo "                         (e.g., make test-edit-drift-detector)"
	@echo "  make clean           - remove validation/results/"
	@echo "  make install TARGET=<path>  - install hooks into <path>"
	@echo "                                (use INSTALL_FLAGS=--with-claude-md for CLAUDE.md)"

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

test-%:
	@cd validation && ./harness.sh $*

clean:
	rm -rf validation/results

install:
	@if [ -z "$(TARGET)" ]; then \
		echo "Error: TARGET=<path> required" >&2; \
		echo "Example: make install TARGET=/path/to/project" >&2; \
		echo "         make install TARGET=/path/to/project INSTALL_FLAGS=--with-claude-md" >&2; \
		exit 1; \
	fi
	./install.sh $(TARGET) $(INSTALL_FLAGS)
