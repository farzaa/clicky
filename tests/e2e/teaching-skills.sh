#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

trap e2e_cleanup EXIT

ensure_clicky_built
start_mock_worker

echo "Resetting prior teaching skills..."
rm -rf "$SKILLS_DIR"
mkdir -p "$SKILLS_DIR"
rm -f "$E2E_PROMPT_FILE"

echo "Phase A: launch Clicky and teach a save workflow..."
launch_clicky /tmp/clicky-e2e-app.log \
  -CLICKY_E2E=1 \
  -CLICKY_WORKER_URL="$WORKER_URL" \
  -CLICKY_INJECT_TRANSCRIPT="how do I save this document?" \
  -CLICKY_INJECT_TRANSCRIPT_2="got it thanks that worked"

SKILL_FILE=""
for _ in $(seq 1 30); do
  if compgen -G "$SKILLS_DIR/*/SKILL.md" >/dev/null; then
    SKILL_FILE="$(ls "$SKILLS_DIR"/*/SKILL.md | head -1)"
    break
  fi
  sleep 1
done

if [[ -z "$SKILL_FILE" ]]; then
  echo "FAIL: no teaching skill written within 30s"
  echo "--- app log ---"
  tail -40 /tmp/clicky-e2e-app.log || true
  echo "--- worker log ---"
  tail -20 /tmp/clicky-e2e-worker.log || true
  exit 1
fi

SKILL_ID="$(basename "$(dirname "$SKILL_FILE")")"
echo "PASS: teaching skill written to $SKILL_FILE"
echo "--- skill preview ---"
head -20 "$SKILL_FILE"

if [[ "$SKILL_ID" != *save* ]]; then
  echo "FAIL: skill slug '$SKILL_ID' does not contain 'save'"
  exit 1
fi

if [[ "$SKILL_ID" == *got* ]] || [[ "$SKILL_ID" == *thanks* ]] || [[ "$SKILL_ID" == *worked* ]]; then
  echo "FAIL: skill slug '$SKILL_ID' contains confirmation phrase tokens"
  exit 1
fi

echo "PASS: skill slug is clean ($SKILL_ID)"

kill "$CLICKY_PID" 2>/dev/null || true
CLICKY_PID=""
sleep 1
rm -f "$E2E_PROMPT_FILE"

echo "Phase B: relaunch Clicky and verify saved skill is injected into prompt..."
launch_clicky /tmp/clicky-e2e-app-read.log \
  -CLICKY_E2E=1 \
  -CLICKY_WORKER_URL="$WORKER_URL" \
  -CLICKY_INJECT_TRANSCRIPT_3="how do I save this document?"

for _ in $(seq 1 30); do
  if [[ -f "$E2E_PROMPT_FILE" ]] && grep -q "teaching skills:" "$E2E_PROMPT_FILE"; then
    if grep -qi "save" "$E2E_PROMPT_FILE"; then
      echo "PASS: saved skill content found in composed system prompt"
      echo "--- prompt preview ---"
      grep -A 8 "teaching skills:" "$E2E_PROMPT_FILE" | head -12
      echo ""
      echo "E2E PASS: Phase A (write) + Phase B (read-path) succeeded"
      exit 0
    fi
  fi
  sleep 1
done

echo "FAIL: composed system prompt did not include saved skill content within 30s"
echo "--- app log ---"
tail -40 /tmp/clicky-e2e-app-read.log || true
if [[ -f "$E2E_PROMPT_FILE" ]]; then
  echo "--- prompt file ---"
  head -40 "$E2E_PROMPT_FILE" || true
else
  echo "prompt file missing: $E2E_PROMPT_FILE"
fi
exit 1
