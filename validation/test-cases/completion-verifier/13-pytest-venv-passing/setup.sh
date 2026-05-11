#!/usr/bin/env bash
set -euo pipefail

mkdir -p "$TEST_DIR/project/.venv/bin"
cat > "$TEST_DIR/project/.venv/bin/python" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "-c" ]; then
  exit 0
fi

if [ "${1:-}" = "-m" ] && [ "${2:-}" = "pytest" ]; then
  echo "LOCAL_VENV_PYTEST_PASS"
  exit 0
fi

echo "unexpected local venv python invocation: $*" >&2
exit 99
SH
chmod +x "$TEST_DIR/project/.venv/bin/python"
