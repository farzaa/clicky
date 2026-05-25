#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLICKY_APP="${CLICKY_APP:-$ROOT_DIR/build/E2E/Clicky.app}"
WORKER_URL="${CLICKY_WORKER_URL:-http://127.0.0.1:8787}"
MOCK_WORKER_PID=""

cleanup() {
  if [[ -n "$MOCK_WORKER_PID" ]]; then
    kill "$MOCK_WORKER_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "=== Clicky full-stack E2E scaffold ==="
echo ""

# Verify headless E2E still works (CI regression)
echo "Step 0: Verify headless teaching-skills E2E..."
chmod +x "$ROOT_DIR/tests/e2e/run-all.sh" "$ROOT_DIR/tests/e2e/teaching-skills.sh"
"$ROOT_DIR/tests/e2e/run-all.sh"
echo "✓ Headless E2E passed"
echo ""

echo "Step 1: Check prerequisites..."
missing=0

if ! brew list blackhole-2ch &>/dev/null 2>&1; then
  echo "  ⚠ BlackHole 2ch not installed (brew install blackhole-2ch)"
  missing=1
else
  echo "  ✓ BlackHole 2ch"
fi

if [[ ! -d "$SCRIPT_DIR/vendor/voice-testing-tools" ]]; then
  echo "  ⚠ voice-testing-tools not cloned — run ./tests/e2e/full-stack/setup.sh"
  missing=1
else
  echo "  ✓ voice-testing-tools"
fi

if [[ ! -d "$CLICKY_APP" ]]; then
  echo "  ⚠ Clicky.app not found at $CLICKY_APP"
  echo "    Run ./tests/e2e/teaching-skills.sh first (builds to build/E2E/Clicky.app)"
  missing=1
else
  echo "  ✓ Clicky.app"
fi

if [[ "$missing" -eq 1 ]]; then
  echo ""
  echo "Some prerequisites missing. Run ./tests/e2e/full-stack/setup.sh"
  echo "Full-stack manual steps are documented in tests/e2e/full-stack/README.md"
  exit 0
fi

echo ""
echo "Step 2: Start mock worker on $WORKER_URL..."
node "$ROOT_DIR/tests/e2e/mock-worker.mjs" >/tmp/clicky-fullstack-worker.log 2>&1 &
MOCK_WORKER_PID=$!
sleep 1
echo "  ✓ Mock worker running (PID $MOCK_WORKER_PID)"

echo ""
echo "Step 3: Manual full-stack test procedure"
echo ""
echo "  A. Pre-grant permissions (one-time on test Mac):"
echo "     npx @guidepup/setup --ci"
echo ""
echo "  B. Route audio through BlackHole:"
echo "     SwitchAudioSource -s \"BlackHole 2ch\""
echo "     Set Clicky mic input to BlackHole 2ch in System Settings"
echo ""
echo "  C. Launch Clicky with mock worker:"
echo "     open \"$CLICKY_APP\" --args -CLICKY_E2E=1 -CLICKY_WORKER_URL=$WORKER_URL"
echo ""
echo "  D. Open a target app (e.g. TextEdit) and simulate PTT + voice:"
echo "     node $SCRIPT_DIR/vendor/voice-testing-tools/tools/tts.mjs \"how do I save this document?\" &"
echo "     swift $SCRIPT_DIR/vendor/voice-testing-tools/tools/simulate-keypress.swift down:ctrl down:option wait:3000 up:option up:ctrl"
echo ""
echo "  E. Assert overlay via accessibility (Peekaboo / axcli):"
echo "     - clicky.overlay.cursor"
echo "     - clicky.overlay.waveform (while listening)"
echo "     - clicky.overlay.spinner (while processing)"
echo "     - clicky.overlay.pointing-bubble (after response with [POINT:...])"
echo ""
echo "  F. Assert skill read path (after teaching a skill):"
echo "     cat ~/.clicky/e2e-last-matched-skill-id.txt"
echo "     cat ~/.clicky/e2e-last-system-prompt.txt"
echo ""
echo "=== Scaffold ready — complete manual steps above on a test Mac ==="
echo "See tests/e2e/full-stack/README.md for full documentation."
