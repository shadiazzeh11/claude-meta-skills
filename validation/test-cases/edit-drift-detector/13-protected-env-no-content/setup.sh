#!/usr/bin/env bash
PROJ="$TEST_DIR/project"
mkdir -p "$PROJ"
cat > "$PROJ/.env.local" <<'EOF'
API_TOKEN=SUPER_SECRET_ENV_VALUE_SHOULD_NOT_LEAK
DATABASE_URL=postgres://example.invalid/app
EOF
