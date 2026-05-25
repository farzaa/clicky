#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CLICKY_APP="${CLICKY_APP:-$ROOT_DIR/build/E2E/Clicky.app}"
WORKER_URL="${CLICKY_WORKER_URL:-http://127.0.0.1:8787}"
NICHE_JSON="$HOME/.clicky/e2e-niche-discovery.json"
PROMPT_FILE="$HOME/.clicky/e2e-last-system-prompt.txt"
BUNDLE_ID="com.yourcompany.leanring-buddy"
# Force bundled JSON suggestions in Phase A/B (avoid app-aware Terminal/VS Code ids in CI).
E2E_UNMAPPED_BUNDLE_ID="com.unknown.app"
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

read_niche_json_field() {
  local field="$1"
  python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$NICHE_JSON" "$field"
}

assert_phase_a_json() {
  if [[ ! -f "$NICHE_JSON" ]]; then
    echo "FAIL: $NICHE_JSON missing"
    return 1
  fi

  local selected_niche suggestion_count first_id clause_token
  selected_niche="$(read_niche_json_field selectedNiche)"
  suggestion_count="$(read_niche_json_field suggestionCount)"
  first_id="$(read_niche_json_field firstSuggestionId)"
  clause_token="$(read_niche_json_field voicePromptClauseContains)"

  if [[ "$selected_niche" != "developer" ]]; then
    echo "FAIL: selectedNiche is '$selected_niche', expected developer"
    return 1
  fi

  if [[ "$suggestion_count" -lt 3 ]]; then
    echo "FAIL: suggestionCount is $suggestion_count, expected >= 3"
    return 1
  fi

  if [[ "$clause_token" != "developer" ]]; then
    echo "FAIL: voicePromptClauseContains is '$clause_token', expected developer"
    return 1
  fi

  local is_app_aware
  is_app_aware="$(read_niche_json_field isAppAware)"
  if [[ "$is_app_aware" == "True" ]]; then
    echo "FAIL: expected bundled suggestions (isAppAware false), got true"
    return 1
  fi

  case "$first_id" in
    commit-changes|run-tests|debug-breakpoint|terminal-command|find-setting) ;;
    *)
      echo "FAIL: firstSuggestionId '$first_id' is not a developer.json id"
      return 1
      ;;
  esac

  echo "PASS: niche discovery JSON — niche=$selected_niche count=$suggestion_count first=$first_id"
  return 0
}

echo "Building Clicky for E2E..."
mkdir -p "$ROOT_DIR/build/E2E"
xcodebuild \
  -project "$ROOT_DIR/leanring-buddy.xcodeproj" \
  -scheme leanring-buddy \
  -destination 'platform=macOS' \
  -derivedDataPath "$ROOT_DIR/build/E2E/DerivedData" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=NO \
  build >/tmp/clicky-e2e-niche-build.log 2>&1 || {
  echo "FAIL: xcodebuild failed"
  tail -40 /tmp/clicky-e2e-niche-build.log || true
  exit 1
}

BUILT_APP="$ROOT_DIR/build/E2E/DerivedData/Build/Products/Debug/Clicky.app"
rm -rf "$CLICKY_APP"
ditto "$BUILT_APP" "$CLICKY_APP"

echo "Phase A: set developer niche and load bundled suggestions..."
defaults delete "$BUNDLE_ID" selectedUserNiche 2>/dev/null || true
rm -f "$NICHE_JSON"

"$CLICKY_APP/Contents/MacOS/Clicky" \
  -CLICKY_E2E=1 \
  -CLICKY_E2E_SET_NICHE=developer \
  -CLICKY_E2E_FRONTMOST_BUNDLE_ID="$E2E_UNMAPPED_BUNDLE_ID" >/tmp/clicky-e2e-niche-app.log 2>&1 &
CLICKY_PID=$!

PHASE_A_OK=0
for _ in $(seq 1 15); do
  if [[ -f "$NICHE_JSON" ]] && assert_phase_a_json; then
    PHASE_A_OK=1
    break
  fi
  sleep 1
done

if [[ "$PHASE_A_OK" -ne 1 ]]; then
  echo "FAIL: Phase A did not produce valid niche discovery JSON within 15s"
  echo "--- app log ---"
  tail -40 /tmp/clicky-e2e-niche-app.log || true
  if [[ -f "$NICHE_JSON" ]]; then
    echo "--- niche json ---"
    cat "$NICHE_JSON" || true
  fi
  exit 1
fi

echo "--- niche json preview ---"
head -20 "$NICHE_JSON"

kill "$CLICKY_PID" 2>/dev/null || true
CLICKY_PID=""
sleep 1

echo "Phase B: verify developer niche persists across relaunch..."
rm -f "$NICHE_JSON"

"$CLICKY_APP/Contents/MacOS/Clicky" \
  -CLICKY_E2E=1 \
  -CLICKY_E2E_FRONTMOST_BUNDLE_ID="$E2E_UNMAPPED_BUNDLE_ID" >/tmp/clicky-e2e-niche-persist.log 2>&1 &
CLICKY_PID=$!

PHASE_B_OK=0
for _ in $(seq 1 15); do
  if [[ -f "$NICHE_JSON" ]]; then
    selected_niche="$(read_niche_json_field selectedNiche)"
    if [[ "$selected_niche" == "developer" ]]; then
      echo "PASS: developer niche persisted after relaunch"
      PHASE_B_OK=1
      break
    fi
  fi
  sleep 1
done

if [[ "$PHASE_B_OK" -ne 1 ]]; then
  echo "FAIL: Phase B persistence check failed within 15s"
  echo "--- app log ---"
  tail -40 /tmp/clicky-e2e-niche-persist.log || true
  if [[ -f "$NICHE_JSON" ]]; then
    cat "$NICHE_JSON" || true
  else
    echo "niche json missing: $NICHE_JSON"
  fi
  exit 1
fi

kill "$CLICKY_PID" 2>/dev/null || true
CLICKY_PID=""
sleep 1

echo "Phase C: verify content-creator niche clause in composed system prompt..."
rm -f "$PROMPT_FILE" "$NICHE_JSON"
defaults delete "$BUNDLE_ID" selectedUserNiche 2>/dev/null || true

echo "Starting mock worker on $WORKER_URL..."
node "$ROOT_DIR/tests/e2e/mock-worker.mjs" >/tmp/clicky-e2e-niche-worker.log 2>&1 &
MOCK_WORKER_PID=$!
sleep 1

"$CLICKY_APP/Contents/MacOS/Clicky" \
  -CLICKY_E2E=1 \
  -CLICKY_WORKER_URL="$WORKER_URL" \
  -CLICKY_E2E_SET_NICHE=content-creator \
  -CLICKY_INJECT_TRANSCRIPT_3="how do I export this video?" >/tmp/clicky-e2e-niche-prompt.log 2>&1 &
CLICKY_PID=$!

PHASE_C_OK=0
for _ in $(seq 1 30); do
  if [[ -f "$PROMPT_FILE" ]] && grep -qi "content creator" "$PROMPT_FILE"; then
    echo "PASS: content-creator niche clause found in composed system prompt"
    echo "--- prompt excerpt ---"
    grep -i "content creator" "$PROMPT_FILE" | head -3
    PHASE_C_OK=1
    break
  fi
  sleep 1
done

if [[ "$PHASE_C_OK" -ne 1 ]]; then
  echo "FAIL: Phase C did not include content-creator niche clause within 30s"
  echo "--- app log ---"
  tail -40 /tmp/clicky-e2e-niche-prompt.log || true
  if [[ -f "$PROMPT_FILE" ]]; then
    echo "--- prompt file ---"
    head -40 "$PROMPT_FILE" || true
  else
    echo "prompt file missing: $PROMPT_FILE"
  fi
  exit 1
fi

echo ""
echo "E2E PASS: Phase A (niche set) + Phase B (persistence) succeeded (+ Phase C niche clause in prompt)"

kill "$CLICKY_PID" 2>/dev/null || true
CLICKY_PID=""
if [[ -n "$MOCK_WORKER_PID" ]]; then
  kill "$MOCK_WORKER_PID" 2>/dev/null || true
  MOCK_WORKER_PID=""
fi
sleep 1

echo "Phase D: verify app-aware Xcode suggestions..."
rm -f "$NICHE_JSON"
defaults delete "$BUNDLE_ID" selectedUserNiche 2>/dev/null || true

"$CLICKY_APP/Contents/MacOS/Clicky" \
  -CLICKY_E2E=1 \
  -CLICKY_E2E_SET_NICHE=developer \
  -CLICKY_E2E_FRONTMOST_BUNDLE_ID=com.apple.dt.Xcode >/tmp/clicky-e2e-niche-app-aware.log 2>&1 &
CLICKY_PID=$!

PHASE_D_OK=0
for _ in $(seq 1 15); do
  if [[ -f "$NICHE_JSON" ]]; then
    is_app_aware="$(read_niche_json_field isAppAware)"
    suggestion_context="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('suggestionContext') or '')" "$NICHE_JSON")"
    first_id="$(read_niche_json_field firstSuggestionId)"

    if [[ "$is_app_aware" == "True" ]] && [[ "$suggestion_context" == *"Xcode"* ]] && [[ "$first_id" == xcode-* ]]; then
      echo "PASS: app-aware Xcode suggestions — context='$suggestion_context' first=$first_id"
      PHASE_D_OK=1
      break
    fi
  fi
  sleep 1
done

if [[ "$PHASE_D_OK" -ne 1 ]]; then
  echo "FAIL: Phase D app-aware check failed within 15s"
  echo "--- app log ---"
  tail -40 /tmp/clicky-e2e-niche-app-aware.log || true
  if [[ -f "$NICHE_JSON" ]]; then
    echo "--- niche json ---"
    cat "$NICHE_JSON" || true
  fi
  exit 1
fi

echo ""
echo "E2E PASS: Phase A + B + C + D (app-aware) succeeded"
