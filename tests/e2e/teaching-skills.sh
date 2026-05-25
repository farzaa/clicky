#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CLICKY_APP="${CLICKY_APP:-$ROOT_DIR/build/E2E/Clicky.app}"
WORKER_URL="${CLICKY_WORKER_URL:-http://127.0.0.1:8787}"
SKILLS_DIR="$HOME/.clicky/skills"
MOCK_WORKER_PID=""
CLICKY_PID=""

cleanup() {
  if [[ -n "$MOCK_WORKER_PID" ]]; then
    kill "$MOCK_WORKER_PID" 2>/dev/null || true
  fi
  if [[ -n "$CLICKY_PID" ]]; then
    kill "$CLICKY_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "Building Clicky for E2E..."
mkdir -p "$ROOT_DIR/build/E2E"
xcodebuild \
  -project "$ROOT_DIR/leanring-buddy.xcodeproj" \
  -scheme leanring-buddy \
  -destination 'platform=macOS' \
  -derivedDataPath "$ROOT_DIR/build/E2E/DerivedData" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=NO \
  build >/tmp/clicky-e2e-build.log 2>&1

BUILT_APP="$ROOT_DIR/build/E2E/DerivedData/Build/Products/Debug/Clicky.app"
rm -rf "$CLICKY_APP"
ditto "$BUILT_APP" "$CLICKY_APP"

echo "Starting mock worker on $WORKER_URL..."
node "$ROOT_DIR/tests/e2e/mock-worker.mjs" >/tmp/clicky-e2e-worker.log 2>&1 &
MOCK_WORKER_PID=$!
sleep 1

echo "Resetting prior teaching skills..."
rm -rf "$SKILLS_DIR"
mkdir -p "$SKILLS_DIR"

echo "Launching Clicky in E2E mode..."
"$CLICKY_APP/Contents/MacOS/Clicky" \
  -CLICKY_E2E=1 \
  -CLICKY_WORKER_URL="$WORKER_URL" \
  -CLICKY_INJECT_TRANSCRIPT="how do I save this document?" \
  -CLICKY_INJECT_TRANSCRIPT_2="got it thanks that worked" >/tmp/clicky-e2e-app.log 2>&1 &
CLICKY_PID=$!

echo "Waiting for skill write..."
for _ in $(seq 1 30); do
  if compgen -G "$SKILLS_DIR/*/SKILL.md" >/dev/null; then
    SKILL_FILE="$(ls "$SKILLS_DIR"/*/SKILL.md | head -1)"
    echo "PASS: teaching skill written to $SKILL_FILE"
    echo "--- skill preview ---"
    head -20 "$SKILL_FILE"
    exit 0
  fi
  sleep 1
done

echo "FAIL: no teaching skill written within 30s"
echo "--- app log ---"
tail -40 /tmp/clicky-e2e-app.log || true
echo "--- worker log ---"
tail -20 /tmp/clicky-e2e-worker.log || true
exit 1
