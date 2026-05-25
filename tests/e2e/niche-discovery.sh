#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

trap e2e_cleanup EXIT

ensure_clicky_built
start_mock_worker

reset_e2e_artifacts

echo "Phase A: developer niche selection and suggestions..."
launch_clicky /tmp/clicky-e2e-niche-a.log \
  -CLICKY_E2E=1 \
  -CLICKY_E2E_INCLUDE_NICHE=1 \
  -CLICKY_E2E_SELECT_NICHE=developer \
  -CLICKY_WORKER_URL="$WORKER_URL"

if ! wait_for_file "$E2E_SELECTED_NICHE_FILE" 30 "selected niche artifact"; then
  print_failure_logs /tmp/clicky-e2e-niche-a.log
  exit 1
fi

SELECTED_NICHE="$(tr -d '[:space:]' <"$E2E_SELECTED_NICHE_FILE")"
if [[ "$SELECTED_NICHE" != "developer" ]]; then
  echo "FAIL: expected e2e-selected-niche.txt == developer, got '$SELECTED_NICHE'"
  exit 1
fi
echo "PASS: selected niche is developer"

if ! wait_for_file_content "$E2E_SUGGESTIONS_FILE" "commit" 30 "developer suggestions"; then
  print_failure_logs /tmp/clicky-e2e-niche-a.log
  cat "$E2E_SUGGESTIONS_FILE" 2>/dev/null || true
  exit 1
fi
echo "PASS: developer suggestions contain 'commit'"
echo "--- suggestions preview ---"
head -10 "$E2E_SUGGESTIONS_FILE"

kill "$CLICKY_PID" 2>/dev/null || true
CLICKY_PID=""
sleep 1

echo ""
echo "Phase B: Xcode app-aware suggestion swap..."
reset_e2e_artifacts

launch_clicky /tmp/clicky-e2e-niche-b.log \
  -CLICKY_E2E=1 \
  -CLICKY_E2E_SELECT_NICHE=developer \
  -CLICKY_E2E_SIMULATE_FRONTMOST_BUNDLE=com.apple.dt.Xcode \
  -CLICKY_WORKER_URL="$WORKER_URL"

if ! wait_for_file_content "$E2E_SUGGESTIONS_FILE" "source control navigator" 30 "Xcode suggestions"; then
  print_failure_logs /tmp/clicky-e2e-niche-b.log
  cat "$E2E_SUGGESTIONS_FILE" 2>/dev/null || true
  exit 1
fi
echo "PASS: Xcode app-aware suggestions include 'source control navigator'"

kill "$CLICKY_PID" 2>/dev/null || true
CLICKY_PID=""
sleep 1

echo ""
echo "Phase C: local niche override..."
reset_e2e_artifacts

OVERRIDE_DIR="$HOME/.clicky/niches/developer"
mkdir -p "$OVERRIDE_DIR"
echo '{"suggestions":["custom developer e2e prompt","another custom prompt"]}' >"$OVERRIDE_DIR/examples.json"

launch_clicky /tmp/clicky-e2e-niche-c.log \
  -CLICKY_E2E=1 \
  -CLICKY_E2E_SELECT_NICHE=developer \
  -CLICKY_WORKER_URL="$WORKER_URL"

if ! wait_for_file_content "$E2E_SUGGESTIONS_FILE" "custom developer e2e prompt" 30 "local override suggestions"; then
  print_failure_logs /tmp/clicky-e2e-niche-c.log
  cat "$E2E_SUGGESTIONS_FILE" 2>/dev/null || true
  exit 1
fi
echo "PASS: local niche override suggestions loaded"

rm -rf "$OVERRIDE_DIR"

echo ""
echo "E2E PASS: niche-discovery (A + B + C) succeeded"
