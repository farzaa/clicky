#!/usr/bin/env bash
# Shared helpers for Clicky headless E2E scripts.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CLICKY_APP="${CLICKY_APP:-$ROOT_DIR/build/E2E/Clicky.app}"
WORKER_URL="${CLICKY_WORKER_URL:-http://127.0.0.1:8787}"
SKILLS_DIR="$HOME/.clicky/skills"
CLICKY_DIR="$HOME/.clicky"

E2E_PROMPT_FILE="$CLICKY_DIR/e2e-last-system-prompt.txt"
E2E_MATCHED_SKILL_FILE="$CLICKY_DIR/e2e-last-matched-skill-id.txt"
E2E_SUGGESTIONS_FILE="$CLICKY_DIR/e2e-last-suggestions.txt"
E2E_SELECTED_NICHE_FILE="$CLICKY_DIR/e2e-selected-niche.txt"
E2E_SKILLS_COUNT_FILE="$CLICKY_DIR/e2e-skills-count.txt"
E2E_LIBRARY_STATE_FILE="$CLICKY_DIR/e2e-skill-library-state.txt"

MOCK_WORKER_PID=""
CLICKY_PID=""

e2e_cleanup() {
  if [[ -n "$MOCK_WORKER_PID" ]]; then
    kill "$MOCK_WORKER_PID" 2>/dev/null || true
    MOCK_WORKER_PID=""
  fi
  if [[ -n "$CLICKY_PID" ]]; then
    kill "$CLICKY_PID" 2>/dev/null || true
    CLICKY_PID=""
  fi
}

ensure_clicky_built() {
  if [[ "${SKIP_E2E_BUILD:-}" == "1" ]] && [[ -d "$CLICKY_APP" ]]; then
    echo "Using existing Clicky build at $CLICKY_APP"
    return 0
  fi

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

  local built_app="$ROOT_DIR/build/E2E/DerivedData/Build/Products/Debug/Clicky.app"
  rm -rf "$CLICKY_APP"
  ditto "$built_app" "$CLICKY_APP"
  echo "Built Clicky at $CLICKY_APP"
}

worker_port_from_url() {
  local url="$1"
  local port="8787"

  if [[ "$url" =~ :([0-9]+)(/|$|\?) ]]; then
    port="${BASH_REMATCH[1]}"
  fi

  echo "$port"
}

start_mock_worker() {
  local worker_port
  worker_port="$(worker_port_from_url "$WORKER_URL")"
  echo "Starting mock worker on $WORKER_URL (port $worker_port)..."
  MOCK_WORKER_PORT="$worker_port" node "$ROOT_DIR/tests/e2e/mock-worker.mjs" >/tmp/clicky-e2e-worker.log 2>&1 &
  MOCK_WORKER_PID=$!
  sleep 1
}

launch_clicky() {
  local log_file="${1:-/tmp/clicky-e2e-app.log}"
  shift || true

  "$CLICKY_APP/Contents/MacOS/Clicky" "$@" >"$log_file" 2>&1 &
  CLICKY_PID=$!
}

wait_for_file() {
  local file_path="$1"
  local timeout_seconds="${2:-30}"
  local description="${3:-$file_path}"

  for _ in $(seq 1 "$timeout_seconds"); do
    if [[ -f "$file_path" ]]; then
      return 0
    fi
    sleep 1
  done

  echo "FAIL: timed out waiting for $description ($file_path)"
  return 1
}

wait_for_file_content() {
  local file_path="$1"
  local pattern="$2"
  local timeout_seconds="${3:-30}"
  local description="${4:-$file_path}"

  for _ in $(seq 1 "$timeout_seconds"); do
    if [[ -f "$file_path" ]] && grep -q "$pattern" "$file_path"; then
      return 0
    fi
    sleep 1
  done

  echo "FAIL: timed out waiting for '$pattern' in $description"
  return 1
}

reset_e2e_artifacts() {
  rm -f \
    "$E2E_PROMPT_FILE" \
    "$E2E_MATCHED_SKILL_FILE" \
    "$E2E_SUGGESTIONS_FILE" \
    "$E2E_SELECTED_NICHE_FILE" \
    "$E2E_SKILLS_COUNT_FILE" \
    "$E2E_LIBRARY_STATE_FILE"
}

seed_teaching_skill() {
  local skill_id="$1"
  local skill_status="$2"
  local skill_pinned="${3:-false}"
  local skill_name="$4"
  local skill_body="$5"

  mkdir -p "$SKILLS_DIR/$skill_id"
  cat >"$SKILLS_DIR/$skill_id/SKILL.md" <<EOF
---
name: $skill_name
description: E2E seeded skill $skill_id
bundleIds:
  - com.apple.TextEdit
status: $skill_status
lastUsed: 2026-05-24
usageCount: 1
pinned: $skill_pinned
---

$skill_body
EOF
}

print_failure_logs() {
  local app_log="${1:-/tmp/clicky-e2e-app.log}"
  echo "--- app log ---"
  tail -40 "$app_log" 2>/dev/null || true
  echo "--- worker log ---"
  tail -20 /tmp/clicky-e2e-worker.log 2>/dev/null || true
}
