#!/usr/bin/env bash
# Create a 0-byte fixture.txt to simulate a file that ended up empty
# despite the Write reporting success with non-empty content.
: > "$TEST_DIR/fixture.txt"
