HOOKS := edit-drift-detector construction-gate silent-file-verifier completion-verifier context-recovery

.PHONY: test test-% clean install help

help:
	@echo "claude-meta-skills make targets:"
	@echo "  make test            - run validation harness for all 5 hooks"
	@echo "  make test-<hook>     - run validation harness for one hook"
	@echo "                         (e.g., make test-edit-drift-detector)"
	@echo "  make clean           - remove validation/results/"
	@echo "  make install TARGET=<path>  - install hooks into <path>"
	@echo "                                (use INSTALL_FLAGS=--with-claude-md for CLAUDE.md)"

test:
	@cd validation && for h in $(HOOKS); do \
		echo "=== $$h ==="; \
		./harness.sh $$h || true; \
		echo; \
	done

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
