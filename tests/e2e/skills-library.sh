#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ACTIVE_SKILL_ID="teach-e2e-active-test"
ARCHIVED_SKILL_ID="teach-e2e-archived-test"

trap e2e_cleanup EXIT

ensure_clicky_built
start_mock_worker

echo "Seeding teaching skills for library E2E..."
rm -rf "$SKILLS_DIR"
mkdir -p "$SKILLS_DIR"
reset_e2e_artifacts

seed_teaching_skill "$ACTIVE_SKILL_ID" "active" "false" "E2E Active Skill" "active skill body for e2e library test"
seed_teaching_skill "$ARCHIVED_SKILL_ID" "archived" "false" "E2E Archived Skill" "archived skill body for e2e library test"

echo "Phase A: write skill library snapshot..."
launch_clicky /tmp/clicky-e2e-library-a.log \
  -CLICKY_E2E=1 \
  -CLICKY_WORKER_URL="$WORKER_URL"

if ! wait_for_file "$E2E_LIBRARY_STATE_FILE" 30 "skill library state artifact"; then
  print_failure_logs /tmp/clicky-e2e-library-a.log
  exit 1
fi

if ! grep -q "\"id\" : \"$ACTIVE_SKILL_ID\"" "$E2E_LIBRARY_STATE_FILE"; then
  echo "FAIL: library state missing active skill $ACTIVE_SKILL_ID"
  cat "$E2E_LIBRARY_STATE_FILE"
  exit 1
fi

if ! grep -q "\"id\" : \"$ARCHIVED_SKILL_ID\"" "$E2E_LIBRARY_STATE_FILE"; then
  echo "FAIL: library state missing archived skill $ARCHIVED_SKILL_ID"
  cat "$E2E_LIBRARY_STATE_FILE"
  exit 1
fi

if ! grep -q "\"status\" : \"active\"" "$E2E_LIBRARY_STATE_FILE"; then
  echo "FAIL: library state missing active status"
  exit 1
fi

if ! grep -q "\"status\" : \"archived\"" "$E2E_LIBRARY_STATE_FILE"; then
  echo "FAIL: library state missing archived status"
  exit 1
fi

echo "PASS: library snapshot contains both seeded skills with correct statuses"
echo "--- library state preview ---"
head -20 "$E2E_LIBRARY_STATE_FILE"

kill "$CLICKY_PID" 2>/dev/null || true
CLICKY_PID=""
sleep 1

echo ""
echo "Phase B: restore archived skill via E2E hook..."
rm -f "$E2E_LIBRARY_STATE_FILE"

launch_clicky /tmp/clicky-e2e-library-b.log \
  -CLICKY_E2E=1 \
  -CLICKY_E2E_RESTORE_SKILL="$ARCHIVED_SKILL_ID" \
  -CLICKY_WORKER_URL="$WORKER_URL"

if ! wait_for_file "$E2E_LIBRARY_STATE_FILE" 30 "updated library state artifact"; then
  print_failure_logs /tmp/clicky-e2e-library-b.log
  exit 1
fi

if ! python3 - <<'PY' "$E2E_LIBRARY_STATE_FILE" "$ARCHIVED_SKILL_ID"
import json, sys
path, skill_id = sys.argv[1], sys.argv[2]
entries = json.load(open(path))
match = next((entry for entry in entries if entry.get("id") == skill_id), None)
if not match:
    raise SystemExit(f"missing skill {skill_id}")
if match.get("status") != "active":
    raise SystemExit(f"expected active after restore, got {match.get('status')}")
print("ok")
PY
then
  echo "FAIL: archived skill was not restored to active"
  cat "$E2E_LIBRARY_STATE_FILE"
  exit 1
fi

echo "PASS: archived skill restored to active in library snapshot"
echo ""
echo "E2E PASS: skills-library (A + B) succeeded"
