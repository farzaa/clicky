#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

trap e2e_cleanup EXIT

# No mapped niche app in Phase A/B — suggestions stay empty until usage or a matching app is frontmost.
E2E_UNMAPPED_BUNDLE_ID="com.unknown.app"

read_niche_json_field() {
  local field="$1"
  python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$E2E_NICHE_JSON" "$field"
}

assert_phase_a_json() {
  if [[ ! -f "$E2E_NICHE_JSON" ]]; then
    echo "FAIL: $E2E_NICHE_JSON missing"
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

  if [[ "$suggestion_count" -ne 0 ]]; then
    echo "FAIL: suggestionCount is $suggestion_count, expected 0 without matching apps"
    return 1
  fi

  if [[ -n "$first_id" ]]; then
    echo "FAIL: firstSuggestionId should be empty without matching apps, got '$first_id'"
    return 1
  fi

  if [[ "$clause_token" != "developer" ]]; then
    echo "FAIL: voicePromptClauseContains is '$clause_token', expected developer"
    return 1
  fi

  local is_app_aware suggestion_context
  is_app_aware="$(read_niche_json_field isAppAware)"
  suggestion_context="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('suggestionContext') or '')" "$E2E_NICHE_JSON")"
  if [[ "$is_app_aware" == "True" ]]; then
    echo "FAIL: expected no app-aware suggestions without matching apps, got true"
    return 1
  fi

  if [[ "$suggestion_context" != *"developer app you use"* ]]; then
    echo "FAIL: expected empty-state context about developer apps, got '$suggestion_context'"
    return 1
  fi

  echo "PASS: niche discovery JSON — niche=$selected_niche count=$suggestion_count (app-only suggestions)"
  return 0
}

ensure_clicky_built
start_mock_worker

reset_e2e_artifacts

echo "Phase A: set developer niche and load bundled suggestions..."
defaults delete "$BUNDLE_ID" selectedUserNiche 2>/dev/null || true

launch_clicky /tmp/clicky-e2e-niche-a.log \
  -CLICKY_E2E=1 \
  -CLICKY_E2E_SET_NICHE=developer \
  -CLICKY_E2E_FRONTMOST_BUNDLE_ID="$E2E_UNMAPPED_BUNDLE_ID" \
  -CLICKY_WORKER_URL="$WORKER_URL"

PHASE_A_OK=0
for _ in $(seq 1 15); do
  if [[ -f "$E2E_NICHE_JSON" ]] && assert_phase_a_json; then
    PHASE_A_OK=1
    break
  fi
  sleep 1
done

if [[ "$PHASE_A_OK" -ne 1 ]]; then
  echo "FAIL: Phase A did not produce valid niche discovery JSON within 15s"
  print_failure_logs /tmp/clicky-e2e-niche-a.log
  if [[ -f "$E2E_NICHE_JSON" ]]; then
    echo "--- niche json ---"
    cat "$E2E_NICHE_JSON" || true
  fi
  exit 1
fi

echo "--- niche json preview ---"
head -20 "$E2E_NICHE_JSON"

kill "$CLICKY_PID" 2>/dev/null || true
CLICKY_PID=""
sleep 1

echo ""
echo "Phase B: verify developer niche persists across relaunch..."
reset_e2e_artifacts

launch_clicky /tmp/clicky-e2e-niche-b.log \
  -CLICKY_E2E=1 \
  -CLICKY_E2E_FRONTMOST_BUNDLE_ID="$E2E_UNMAPPED_BUNDLE_ID" \
  -CLICKY_WORKER_URL="$WORKER_URL"

PHASE_B_OK=0
for _ in $(seq 1 15); do
  if [[ -f "$E2E_NICHE_JSON" ]]; then
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
  print_failure_logs /tmp/clicky-e2e-niche-b.log
  if [[ -f "$E2E_NICHE_JSON" ]]; then
    cat "$E2E_NICHE_JSON" || true
  else
    echo "niche json missing: $E2E_NICHE_JSON"
  fi
  exit 1
fi

kill "$CLICKY_PID" 2>/dev/null || true
CLICKY_PID=""
sleep 1

echo ""
echo "Phase C: verify content-creator niche clause in composed system prompt..."
reset_e2e_artifacts
defaults delete "$BUNDLE_ID" selectedUserNiche 2>/dev/null || true

launch_clicky /tmp/clicky-e2e-niche-c.log \
  -CLICKY_E2E=1 \
  -CLICKY_WORKER_URL="$WORKER_URL" \
  -CLICKY_E2E_SET_NICHE=content-creator \
  -CLICKY_INJECT_TRANSCRIPT_3="how do I export this video?"

PHASE_C_OK=0
for _ in $(seq 1 30); do
  if [[ -f "$E2E_PROMPT_FILE" ]] && grep -qi "content creator" "$E2E_PROMPT_FILE"; then
    echo "PASS: content-creator niche clause found in composed system prompt"
    echo "--- prompt excerpt ---"
    grep -i "content creator" "$E2E_PROMPT_FILE" | head -3
    PHASE_C_OK=1
    break
  fi
  sleep 1
done

if [[ "$PHASE_C_OK" -ne 1 ]]; then
  echo "FAIL: Phase C did not include content-creator niche clause within 30s"
  print_failure_logs /tmp/clicky-e2e-niche-c.log
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

echo ""
echo "Phase D: verify app-aware Xcode suggestions..."
reset_e2e_artifacts
defaults delete "$BUNDLE_ID" selectedUserNiche 2>/dev/null || true

launch_clicky /tmp/clicky-e2e-niche-d.log \
  -CLICKY_E2E=1 \
  -CLICKY_E2E_SET_NICHE=developer \
  -CLICKY_E2E_FRONTMOST_BUNDLE_ID=com.apple.dt.Xcode \
  -CLICKY_WORKER_URL="$WORKER_URL"

PHASE_D_OK=0
for _ in $(seq 1 15); do
  if [[ -f "$E2E_NICHE_JSON" ]]; then
    is_app_aware="$(read_niche_json_field isAppAware)"
    suggestion_context="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('suggestionContext') or '')" "$E2E_NICHE_JSON")"
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
  print_failure_logs /tmp/clicky-e2e-niche-d.log
  if [[ -f "$E2E_NICHE_JSON" ]]; then
    echo "--- niche json ---"
    cat "$E2E_NICHE_JSON" || true
  fi
  exit 1
fi

kill "$CLICKY_PID" 2>/dev/null || true
CLICKY_PID=""
sleep 1

echo ""
echo "Phase E: verify suggestion tap injects hidden context into system prompt..."
reset_e2e_artifacts
defaults delete "$BUNDLE_ID" selectedUserNiche 2>/dev/null || true

launch_clicky /tmp/clicky-e2e-niche-e.log \
  -CLICKY_E2E=1 \
  -CLICKY_WORKER_URL="$WORKER_URL" \
  -CLICKY_E2E_FRONTMOST_BUNDLE_ID=com.mitchellh.ghostty \
  -CLICKY_E2E_TAP_SUGGESTION=ghostty-command

PHASE_E_OK=0
for _ in $(seq 1 30); do
  if [[ -f "$E2E_PROMPT_FILE" ]] && grep -qi "suggestion tap context" "$E2E_PROMPT_FILE"; then
    echo "PASS: suggestion tap hidden context found in composed system prompt"
    echo "--- prompt excerpt ---"
    grep -i "suggestion tap context" "$E2E_PROMPT_FILE" | head -3
    PHASE_E_OK=1
    break
  fi
  sleep 1
done

if [[ "$PHASE_E_OK" -ne 1 ]]; then
  echo "FAIL: Phase E did not include suggestion tap context within 30s"
  print_failure_logs /tmp/clicky-e2e-niche-e.log
  if [[ -f "$E2E_PROMPT_FILE" ]]; then
    echo "--- prompt file ---"
    head -40 "$E2E_PROMPT_FILE" || true
  else
    echo "prompt file missing: $E2E_PROMPT_FILE"
  fi
  exit 1
fi

echo ""
echo "E2E PASS: Phase A + B + C + D + E (niche discovery) succeeded"
