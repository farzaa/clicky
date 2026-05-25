#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENDOR_DIR="$SCRIPT_DIR/vendor/voice-testing-tools"

echo "=== Clicky full-stack E2E setup ==="
echo ""

echo "1. BlackHole 2ch (virtual audio for mic injection)"
if brew list blackhole-2ch &>/dev/null; then
  echo "   ✓ blackhole-2ch installed"
else
  echo "   Install with: brew install blackhole-2ch"
fi

echo ""
echo "2. Audio routing helpers"
if brew list sox &>/dev/null && brew list switchaudio-osx &>/dev/null; then
  echo "   ✓ sox and switchaudio-osx installed"
else
  echo "   Install with: brew install sox switchaudio-osx"
fi

echo ""
echo "3. TCC permission seeding (@guidepup/setup)"
echo "   Run once on a dedicated test Mac:"
echo "   npx @guidepup/setup --ci"
echo "   Docs: https://github.com/guidepup/setup"

echo ""
echo "4. voice-testing-tools (PTT + TTS simulation)"
if [[ -d "$VENDOR_DIR/.git" ]]; then
  echo "   ✓ Already cloned at $VENDOR_DIR"
else
  echo "   Cloning NaryaAI/voice-testing-tools..."
  mkdir -p "$SCRIPT_DIR/vendor"
  git clone --depth 1 https://github.com/NaryaAI/voice-testing-tools.git "$VENDOR_DIR"
  echo "   ✓ Cloned to $VENDOR_DIR"
fi

echo ""
echo "5. Node.js (mock worker + tts.mjs)"
if command -v node &>/dev/null; then
  echo "   ✓ node $(node --version)"
else
  echo "   Install Node.js 20+ (required for mock worker and tts.mjs)"
fi

echo ""
echo "6. Code signing"
echo "   Use a stable dev or Developer ID certificate so TCC permissions persist across rebuilds."
echo "   Ad-hoc signing (CODE_SIGN_IDENTITY=\"-\") resets permissions on every build."

echo ""
echo "=== Setup complete ==="
echo "Next: build Clicky, then run ./tests/e2e/full-stack/run-full-stack.sh"
