#!/usr/bin/env bash
# Project with notebooks/demo.ipynb that exists. Hook receives cwd=$PROJ,
# notebook_path="notebooks/demo.ipynb" (relative). Hook should resolve
# to $PROJ/notebooks/demo.ipynb, find it exists, and exit silently
# (no missing-file warning). NotebookEdit's notebook_path field uses
# the same resolution path as Write/Edit/MultiEdit's file_path.
PROJ="$TEST_DIR/project"
rm -rf "$PROJ"
mkdir -p "$PROJ/notebooks"
printf '{}\n' > "$PROJ/notebooks/demo.ipynb"
