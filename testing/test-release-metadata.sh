#!/usr/bin/env bash
# Validate release metadata that affects Claude Code plugin updates.
#
# Claude Code resolves plugin updates from the explicit plugin.json version
# before marketplace entry versions or source commits. If this repo keeps a
# plugin.json version, it must be bumped deliberately for each public release.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PLUGIN=".claude-plugin/plugin.json"
MARKETPLACE=".claude-plugin/marketplace.json"
VERSION_ARG="${VERSION:-${1:-}}"
SEMVER_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?(\+([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?$'

is_semver() {
  [[ "$1" =~ $SEMVER_RE ]]
}

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required for release metadata checks" >&2
  exit 1
fi

echo "Test: plugin release metadata parses"
jq -e . "$PLUGIN" >/dev/null
jq -e . "$MARKETPLACE" >/dev/null

echo "Test: semantic version parser"
for valid in 0.1.1 1.0.0 1.2.3-alpha 1.2.3-alpha.1 1.2.3-0.3.7 1.2.3-x.7.z.92 1.2.3+build.1 1.2.3-alpha+build.1; do
  if ! is_semver "$valid"; then
    echo "FAIL: expected valid SemVer to pass: $valid" >&2
    exit 1
  fi
done
for invalid in 01.2.3 1.02.3 1.2.03 1.2 1.2.3-alpha..1 1.2.3-01 1.2.3+build..1 v1.2.3; do
  if is_semver "$invalid"; then
    echo "FAIL: expected invalid SemVer to fail: $invalid" >&2
    exit 1
  fi
done

PLUGIN_VERSION="$(jq -r '.version // empty' "$PLUGIN")"
if [ -z "$PLUGIN_VERSION" ]; then
  echo "FAIL: $PLUGIN must declare version because releases use explicit plugin versions" >&2
  exit 1
fi

if ! is_semver "$PLUGIN_VERSION"; then
  echo "FAIL: plugin version must be SemVer without a leading v: $PLUGIN_VERSION" >&2
  exit 1
fi

if jq -e 'any(.plugins[]?; has("version"))' "$MARKETPLACE" >/dev/null; then
  echo "FAIL: marketplace plugin entry must not duplicate plugin.json version" >&2
  exit 1
fi

MARKETPLACE_PLUGIN="$(jq -r '.plugins[0].name // empty' "$MARKETPLACE")"
PLUGIN_NAME="$(jq -r '.name // empty' "$PLUGIN")"
if [ "$MARKETPLACE_PLUGIN" != "$PLUGIN_NAME" ]; then
  echo "FAIL: marketplace plugin name must match plugin.json name" >&2
  echo "  plugin.json: $PLUGIN_NAME" >&2
  echo "  marketplace: $MARKETPLACE_PLUGIN" >&2
  exit 1
fi

if [ -n "$VERSION_ARG" ]; then
  EXPECTED="${VERSION_ARG#v}"
  if [ "$PLUGIN_VERSION" != "$EXPECTED" ]; then
    echo "FAIL: plugin.json version must match requested release VERSION" >&2
    echo "  VERSION:     $VERSION_ARG" >&2
    echo "  plugin.json: $PLUGIN_VERSION" >&2
    exit 1
  fi

  if ! grep -qE "^## \\[$EXPECTED\\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$" CHANGELOG.md; then
    echo "FAIL: CHANGELOG.md must contain a dated section for [$EXPECTED] before tagging" >&2
    exit 1
  fi

  echo "Release VERSION $VERSION_ARG matches plugin metadata"
else
  echo "No VERSION provided; validated plugin version shape and marketplace consistency only"
fi

echo "All release metadata tests passed."
