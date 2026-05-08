#!/usr/bin/env bash
# Create empty fixture.txt: a Write of "" content should produce a 0-byte
# file, which is correct behavior (no warning).
: > "$TEST_DIR/fixture.txt"
