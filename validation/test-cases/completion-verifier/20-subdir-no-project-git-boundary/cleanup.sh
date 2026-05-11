#!/usr/bin/env bash
# This fixture generates its whole project tree at runtime because it needs a
# nested git repository. Remove it after the case so git status stays clean.
rm -rf "$TEST_DIR/project"
