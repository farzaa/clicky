#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

FULL_STACK=false
for arg in "$@"; do
  case "$arg" in
    --full-stack)
      FULL_STACK=true
      ;;
  esac
done

ensure_clicky_built
export SKIP_E2E_BUILD=1

HEADLESS_SCRIPTS=(
  teaching-skills.sh
  niche-discovery.sh
  skills-library.sh
  full-user-journey.sh
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

if [[ "$FULL_STACK" == "true" ]]; then
  echo "----------------------------------------"
  echo "Running full-stack automated runner"
  echo "----------------------------------------"
  bash "$SCRIPT_DIR/full-stack/run-automated.sh"
fi

echo "=== E2E run-all PASS ==="
