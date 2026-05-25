#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Running Clicky teaching-skills E2E..."
echo ""

exec "$SCRIPT_DIR/teaching-skills.sh" "$@"
