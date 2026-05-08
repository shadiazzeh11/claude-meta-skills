#!/usr/bin/env bash
# Replace the hook's rules.json with one containing invalid regex.
# Hook should skip the invalid pattern, not crash.
HOOK_DIR="$(cd "$TEST_DIR/../../.." && pwd)/hooks/construction-gate"
mkdir -p "$TEST_DIR"
# Save original rules.json so cleanup can restore.
cp "$HOOK_DIR/rules.json" "$TEST_DIR/rules.json.original" 2>/dev/null || true
cat > "$HOOK_DIR/rules.json" <<'EOF'
{
  "_description": "Test rules with one invalid regex; hook must skip it.",
  "protected_patterns": [
    "[invalid(regex",
    "node_modules/"
  ]
}
EOF
