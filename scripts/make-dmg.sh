#!/usr/bin/env bash
#
# make-dmg.sh — package an exported, signed YardTalk.app into a distributable
# DMG, then (optionally) notarize and staple it.
#
# IMPORTANT: this script does NOT build or archive. Running `xcodebuild` from
# the terminal invalidates YardTalk's TCC grants (Screen Recording, Microphone,
# Accessibility) on this machine — see CLAUDE.md. So you archive + export in
# Xcode first (Product ▸ Archive ▸ Distribute App ▸ Direct Distribution), then
# point this script at the exported .app.
#
# Usage:
#   scripts/make-dmg.sh /path/to/YardTalk.app [output.dmg]
#
# Notarization (optional but required for Gatekeeper on other Macs). Set these
# env vars to notarize + staple automatically; omit them to just build the DMG:
#   NOTARY_APPLE_ID   — your Apple ID email (mj1@duck.com)
#   NOTARY_TEAM_ID    — Developer ID team (263YH9X3BU)
#   NOTARY_PASSWORD   — an app-specific password (appleid.apple.com), NOT your
#                       login password. Tip: store it once in Keychain with
#                         xcrun notarytool store-credentials YardTalkNotary \
#                           --apple-id mj1@duck.com --team-id 263YH9X3BU
#                       then export NOTARY_PROFILE=YardTalkNotary instead of the
#                       three vars above.
#
set -euo pipefail

APP="${1:-}"
OUT_DMG="${2:-YardTalk.dmg}"
VOL_NAME="YardTalk"
DMG_BACKGROUND="$(cd "$(dirname "$0")/.." && pwd)/dmg-background.png"

if [[ -z "$APP" || ! -d "$APP" ]]; then
  echo "error: pass the path to an exported YardTalk.app" >&2
  echo "usage: $0 /path/to/YardTalk.app [output.dmg]" >&2
  exit 1
fi

echo "==> Verifying the app is signed with a Developer ID identity"
if ! codesign -dv --verbose=2 "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
  echo "warning: '$APP' is not signed with a Developer ID Application cert." >&2
  echo "         Gatekeeper will block it on other Macs. Export via Xcode's" >&2
  echo "         'Direct Distribution (Developer ID)' option, then re-run." >&2
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> Staging DMG contents"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"        # drag-to-install target
if [[ -f "$DMG_BACKGROUND" ]]; then
  mkdir -p "$STAGE/.background"
  cp "$DMG_BACKGROUND" "$STAGE/.background/background.png"
fi

echo "==> Building $OUT_DMG"
rm -f "$OUT_DMG"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$OUT_DMG"

# Notarize the DMG itself, then staple the ticket so first launch works offline.
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> Notarizing with stored credentials profile '$NOTARY_PROFILE'"
  xcrun notarytool submit "$OUT_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUT_DMG"
  echo "==> Notarized + stapled."
elif [[ -n "${NOTARY_APPLE_ID:-}" && -n "${NOTARY_TEAM_ID:-}" && -n "${NOTARY_PASSWORD:-}" ]]; then
  echo "==> Notarizing with Apple ID credentials"
  xcrun notarytool submit "$OUT_DMG" \
    --apple-id "$NOTARY_APPLE_ID" \
    --team-id "$NOTARY_TEAM_ID" \
    --password "$NOTARY_PASSWORD" \
    --wait
  xcrun stapler staple "$OUT_DMG"
  echo "==> Notarized + stapled."
else
  echo "==> Skipped notarization (no NOTARY_* env vars set)."
  echo "    The DMG is built but NOT notarized — Gatekeeper will warn on other Macs."
fi

echo "==> Verifying Gatekeeper acceptance"
spctl -a -t open --context context:primary-signed -v "$OUT_DMG" 2>&1 || \
  echo "    (spctl check is informational; a clean notarized DMG should pass)"

echo "Done: $OUT_DMG"
