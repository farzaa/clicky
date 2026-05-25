#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

trap e2e_cleanup EXIT

ensure_clicky_built
start_mock_worker

echo "=== Full user journey (headless demo success story) ==="
echo ""

echo "Step 1: reset skills and E2E artifacts..."
rm -rf "$SKILLS_DIR"
mkdir -p "$SKILLS_DIR"
reset_e2e_artifacts

echo "Step 2: Session 1 — teach save workflow (write path)..."
launch_clicky /tmp/clicky-e2e-journey-write.log \
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
  print_failure_logs /tmp/clicky-e2e-journey-write.log
  exit 1
fi

SAVED_SKILL_ID="$(basename "$(dirname "$SKILL_FILE")")"
echo "PASS: skill written to $SKILL_FILE (id=$SAVED_SKILL_ID)"

if ! wait_for_file "$E2E_SKILLS_COUNT_FILE" 30 "skills count artifact"; then
  print_failure_logs /tmp/clicky-e2e-journey-write.log
  exit 1
fi

SKILLS_COUNT="$(tr -d '[:space:]' <"$E2E_SKILLS_COUNT_FILE")"
if [[ "$SKILLS_COUNT" -lt 1 ]]; then
  echo "FAIL: e2e-skills-count.txt expected >= 1, got '$SKILLS_COUNT'"
  exit 1
fi
echo "PASS: e2e-skills-count.txt = $SKILLS_COUNT"

kill "$CLICKY_PID" 2>/dev/null || true
CLICKY_PID=""
sleep 1

echo ""
echo "Step 3: Session 2 — recall saved skill (read path)..."
rm -f "$E2E_PROMPT_FILE" "$E2E_MATCHED_SKILL_FILE"

launch_clicky /tmp/clicky-e2e-journey-read.log \
  -CLICKY_E2E=1 \
  -CLICKY_WORKER_URL="$WORKER_URL" \
  -CLICKY_INJECT_TRANSCRIPT_3="how do I save this document?"

if ! wait_for_file "$E2E_MATCHED_SKILL_FILE" 30 "matched skill id artifact"; then
  print_failure_logs /tmp/clicky-e2e-journey-read.log
  exit 1
fi

MATCHED_SKILL_ID="$(tr -d '[:space:]' <"$E2E_MATCHED_SKILL_FILE")"
if [[ "$MATCHED_SKILL_ID" != "$SAVED_SKILL_ID" ]]; then
  echo "FAIL: matched skill '$MATCHED_SKILL_ID' != saved skill '$SAVED_SKILL_ID'"
  exit 1
fi
echo "PASS: e2e-last-matched-skill-id.txt matches saved skill"

if ! wait_for_file_content "$E2E_PROMPT_FILE" "teaching skills:" 30 "composed system prompt"; then
  print_failure_logs /tmp/clicky-e2e-journey-read.log
  exit 1
fi

if ! grep -qi "save" "$E2E_PROMPT_FILE"; then
  echo "FAIL: composed prompt missing saved skill content"
  head -40 "$E2E_PROMPT_FILE" || true
  exit 1
fi
echo "PASS: composed prompt includes teaching skills and save content"

kill "$CLICKY_PID" 2>/dev/null || true
CLICKY_PID=""
sleep 1

echo ""
echo "Step 4: Niche — developer selection..."
reset_e2e_artifacts

launch_clicky /tmp/clicky-e2e-journey-niche-a.log \
  -CLICKY_E2E=1 \
  -CLICKY_E2E_INCLUDE_NICHE=1 \
  -CLICKY_E2E_SELECT_NICHE=developer \
  -CLICKY_WORKER_URL="$WORKER_URL"

if ! wait_for_file_content "$E2E_SELECTED_NICHE_FILE" "developer" 30 "selected niche"; then
  print_failure_logs /tmp/clicky-e2e-journey-niche-a.log
  exit 1
fi
if ! wait_for_file_content "$E2E_SUGGESTIONS_FILE" "commit" 30 "developer suggestions"; then
  print_failure_logs /tmp/clicky-e2e-journey-niche-a.log
  exit 1
fi
echo "PASS: developer niche and suggestions verified"

kill "$CLICKY_PID" 2>/dev/null || true
CLICKY_PID=""
sleep 1

echo ""
echo "Step 5: Niche — Xcode app-aware swap..."
rm -f "$E2E_SUGGESTIONS_FILE"

launch_clicky /tmp/clicky-e2e-journey-niche-b.log \
  -CLICKY_E2E=1 \
  -CLICKY_E2E_SELECT_NICHE=developer \
  -CLICKY_E2E_SIMULATE_FRONTMOST_BUNDLE=com.apple.dt.Xcode \
  -CLICKY_WORKER_URL="$WORKER_URL"

if ! wait_for_file_content "$E2E_SUGGESTIONS_FILE" "source control navigator" 30 "Xcode suggestions"; then
  print_failure_logs /tmp/clicky-e2e-journey-niche-b.log
  cat "$E2E_SUGGESTIONS_FILE" 2>/dev/null || true
  exit 1
fi
echo "PASS: Xcode app-aware suggestions verified"

echo ""
echo "E2E PASS: full-user-journey succeeded"
echo "  write skill: $SAVED_SKILL_ID"
echo "  read match:  $MATCHED_SKILL_ID"
echo "  skills count: $SKILLS_COUNT"
