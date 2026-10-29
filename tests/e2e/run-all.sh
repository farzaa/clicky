#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ensure_clicky_built
export SKIP_E2E_BUILD=1

HEADLESS_SCRIPTS=(
  teaching-skills.sh
  skills-library.sh
)

echo "=== Clicky E2E run-all ==="
echo ""

for headless_script in "${HEADLESS_SCRIPTS[@]}"; do
  echo "----------------------------------------"
  echo "Running $headless_script"
  echo "----------------------------------------"
  bash "$SCRIPT_DIR/$headless_script"
  echo ""
done

echo "=== E2E run-all PASS ==="
