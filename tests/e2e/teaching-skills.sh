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
  -CLICKY_INJECT_TRANSCRIPT="how do I save this document in TextEdit?" \
  -CLICKY_INJECT_TRANSCRIPT_2="got it thanks that worked"

SKILL_FILE=""
for _ in $(seq 1 90); do
  if compgen -G "$SKILLS_DIR/*/SKILL.md" >/dev/null; then
    SKILL_FILE="$(ls "$SKILLS_DIR"/*/SKILL.md | head -1)"
    break
  fi
  sleep 1
done

if [[ -z "$SKILL_FILE" ]]; then
  echo "FAIL: no teaching skill written within 90s"
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

if [[ "$SKILL_ID" != "teach-textedit-save" ]]; then
  echo "FAIL: expected skill id teach-textedit-save, got '$SKILL_ID'"
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
  -CLICKY_INJECT_TRANSCRIPT_3="how do I save this document in TextEdit?"

for _ in $(seq 1 90); do
  if [[ -f "$E2E_PROMPT_FILE" ]] && grep -q "teaching skills:" "$E2E_PROMPT_FILE"; then
    if grep -qi "save" "$E2E_PROMPT_FILE"; then
      echo "PASS: saved skill content found in composed system prompt"
      echo "--- prompt preview ---"
      grep -A 8 "teaching skills:" "$E2E_PROMPT_FILE" | head -12
      break
    fi
  fi
  sleep 1
done

if [[ ! -f "$E2E_PROMPT_FILE" ]] || ! grep -q "teaching skills:" "$E2E_PROMPT_FILE"; then
  echo "FAIL: composed system prompt did not include saved skill content within 90s"
  echo "--- app log ---"
  tail -40 /tmp/clicky-e2e-app-read.log || true
  if [[ -f "$E2E_PROMPT_FILE" ]]; then
    echo "--- prompt file ---"
    head -40 "$E2E_PROMPT_FILE" || true
  else
    echo "prompt file missing: $E2E_PROMPT_FILE"
  fi
  exit 1
fi

kill "$CLICKY_PID" 2>/dev/null || true
CLICKY_PID=""
sleep 1

SKILL_COUNT_BEFORE_PATCH="$(find "$SKILLS_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"

echo "Phase C: patch existing skill after refinement + confirmation..."
launch_clicky /tmp/clicky-e2e-app-patch.log \
  -CLICKY_E2E=1 \
  -CLICKY_WORKER_URL="$WORKER_URL" \
  -CLICKY_INJECT_TRANSCRIPT="how do I save this document in TextEdit?" \
  -CLICKY_INJECT_TRANSCRIPT_2="only use the keyboard shortcut not the file menu" \
  -CLICKY_INJECT_TRANSCRIPT_3="got it thanks that worked"

for _ in $(seq 1 90); do
  if [[ -f "$SKILL_FILE" ]] && grep -qi "keyboard shortcut only\|avoid the file menu" "$SKILL_FILE"; then
    break
  fi
  sleep 1
done

SKILL_COUNT_AFTER_PATCH="$(find "$SKILLS_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"

if [[ "$SKILL_COUNT_AFTER_PATCH" != "$SKILL_COUNT_BEFORE_PATCH" ]]; then
  echo "FAIL: expected $SKILL_COUNT_BEFORE_PATCH skill folder(s) after patch, found $SKILL_COUNT_AFTER_PATCH"
  ls -la "$SKILLS_DIR" || true
  exit 1
fi

if [[ "$(basename "$(dirname "$SKILL_FILE")")" != "teach-textedit-save" ]]; then
  echo "FAIL: expected patched skill id teach-textedit-save, got $(basename "$(dirname "$SKILL_FILE")")"
  exit 1
fi

if ! grep -qi "keyboard shortcut only\|avoid the file menu" "$SKILL_FILE"; then
  echo "FAIL: patched skill body did not include keyboard-only refinement"
  echo "--- skill body ---"
  tail -20 "$SKILL_FILE" || true
  exit 1
fi

echo "PASS: existing skill patched in place ($SKILL_ID)"
echo ""
echo "E2E PASS: Phase A (write) + Phase B (read-path) + Phase C (patch) succeeded"
exit 0
