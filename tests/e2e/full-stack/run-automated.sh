#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
E2E_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$E2E_DIR/lib/common.sh"

VOICE_TOOLS_DIR="$SCRIPT_DIR/vendor/voice-testing-tools"
FULL_STACK_LOG="/tmp/clicky-fullstack-automated.log"

check_prerequisites() {
  local missing_reasons=()

  if ! command -v node >/dev/null 2>&1; then
    missing_reasons+=("node not installed")
  fi

  if ! brew list blackhole-2ch >/dev/null 2>&1; then
    missing_reasons+=("blackhole-2ch not installed (brew install blackhole-2ch)")
  fi

  if [[ ! -f "$VOICE_TOOLS_DIR/tools/simulate-keypress.swift" ]] || [[ ! -f "$VOICE_TOOLS_DIR/tools/tts.mjs" ]]; then
    missing_reasons+=("voice-testing-tools not cloned — run ./tests/e2e/full-stack/setup.sh")
  fi

  if ! command -v SwitchAudioSource >/dev/null 2>&1; then
    missing_reasons+=("SwitchAudioSource not installed (brew install switchaudio-osx)")
  fi

  if [[ ${#missing_reasons[@]} -gt 0 ]]; then
    echo "SKIPPED: full-stack prerequisites not met"
    for reason in "${missing_reasons[@]}"; do
      echo "  - $reason"
    done
    exit 0
  fi
}

simulate_push_to_talk() {
  local spoken_text="$1"
  local hold_seconds="${2:-3}"

  node "$VOICE_TOOLS_DIR/tools/tts.mjs" "$spoken_text" &
  local tts_pid=$!
  sleep 0.5
  swift "$VOICE_TOOLS_DIR/tools/simulate-keypress.swift" \
    down:ctrl down:option "wait:$((hold_seconds * 1000))" up:option up:ctrl
  wait "$tts_pid" 2>/dev/null || true
}

trap e2e_cleanup EXIT

echo "=== Clicky full-stack automated E2E ==="
check_prerequisites

if [[ -d "$CLICKY_APP" ]]; then
  export SKIP_E2E_BUILD=1
  echo "Reusing existing Clicky build at $CLICKY_APP (preserves code signing/TCC)"
else
  echo "WARNING: building Clicky with ad-hoc signing — TCC permissions may reset after this build"
fi

ensure_clicky_built
start_mock_worker

echo "Resetting skills and E2E artifacts..."
rm -rf "$SKILLS_DIR"
mkdir -p "$SKILLS_DIR"
reset_e2e_artifacts

echo "Opening TextEdit as fixture app..."
open -a TextEdit || true
sleep 2

echo "Launching Clicky (real voice path, no transcript inject)..."
launch_clicky "$FULL_STACK_LOG" \
  -CLICKY_E2E=1 \
  -CLICKY_WORKER_URL="$WORKER_URL"

sleep 3

if command -v SwitchAudioSource >/dev/null 2>&1; then
  echo "Routing system audio to BlackHole 2ch (best-effort)..."
  SwitchAudioSource -s "BlackHole 2ch" >/dev/null 2>&1 || \
    echo "WARNING: could not switch output to BlackHole — set mic input manually"
fi

echo "Phase 1: PTT question..."
simulate_push_to_talk "how do I save this document?" 4

if command -v axcli >/dev/null 2>&1; then
  bash "$SCRIPT_DIR/clicky-overlay.axcli.sh" clicky.overlay.waveform 10 || true
else
  echo "WARNING: axcli not installed — skipping overlay waveform assertion"
fi

sleep 2

echo "Phase 1: PTT confirmation..."
simulate_push_to_talk "got it thanks that worked" 3

SKILL_FILE=""
for _ in $(seq 1 45); do
  if compgen -G "$SKILLS_DIR/*/SKILL.md" >/dev/null; then
    SKILL_FILE="$(ls "$SKILLS_DIR"/*/SKILL.md | head -1)"
    break
  fi
  sleep 1
done

if [[ -z "$SKILL_FILE" ]]; then
  echo "FAIL: no teaching skill written within 45s (full-stack path)"
  print_failure_logs "$FULL_STACK_LOG"
  exit 1
fi

SAVED_SKILL_ID="$(basename "$(dirname "$SKILL_FILE")")"
echo "PASS: skill written at $SKILL_FILE"

if command -v axcli >/dev/null 2>&1; then
  bash "$SCRIPT_DIR/clicky-overlay.axcli.sh" clicky.overlay.cursor 15 || \
    bash "$SCRIPT_DIR/clicky-overlay.axcli.sh" clicky.overlay.pointing-bubble 15 || \
    echo "WARNING: overlay cursor/pointing bubble not found via axcli"
else
  echo "WARNING: axcli not installed — using file artifacts only for overlay checks"
fi

kill "$CLICKY_PID" 2>/dev/null || true
CLICKY_PID=""
sleep 2

echo ""
echo "Phase 2: relaunch and PTT same question (read path)..."
rm -f "$E2E_MATCHED_SKILL_FILE" "$E2E_PROMPT_FILE"

launch_clicky /tmp/clicky-fullstack-read.log \
  -CLICKY_E2E=1 \
  -CLICKY_WORKER_URL="$WORKER_URL"

sleep 3
simulate_push_to_talk "how do I save this document?" 4

if ! wait_for_file "$E2E_MATCHED_SKILL_FILE" 45 "matched skill id artifact"; then
  print_failure_logs /tmp/clicky-fullstack-read.log
  exit 1
fi

MATCHED_SKILL_ID="$(tr -d '[:space:]' <"$E2E_MATCHED_SKILL_FILE")"
if [[ "$MATCHED_SKILL_ID" != "$SAVED_SKILL_ID" ]]; then
  echo "FAIL: matched skill '$MATCHED_SKILL_ID' != saved '$SAVED_SKILL_ID'"
  exit 1
fi

echo "PASS: full-stack read path matched saved skill ($MATCHED_SKILL_ID)"
echo ""
echo "FULL-STACK PASS: real PTT journey succeeded"
