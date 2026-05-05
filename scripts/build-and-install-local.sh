#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${CLICKY_APP_PATH:-$HOME/Applications/Clicky.app}"
SWIFT_BIN="${SWIFT_BIN:-$HOME/.swiftly/bin/swift}"
if [[ ! -x "$SWIFT_BIN" ]]; then
  SWIFT_BIN="$(command -v swift)"
fi

cd "$ROOT"
"$SWIFT_BIN" build -c release --product Clicky --disable-sandbox

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$ROOT/.build/release/Clicky" "$APP/Contents/MacOS/Clicky"
chmod +x "$APP/Contents/MacOS/Clicky"
cp "$ROOT/leanring-buddy/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable Clicky' "$APP/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string Clicky' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier so.clicky.gpt55.local' "$APP/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string so.clicky.gpt55.local' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Clicky' "$APP/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Add :CFBundleName string Clicky' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Clicky' "$APP/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Add :CFBundleDisplayName string Clicky' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.1-gpt55' "$APP/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Add :CFBundleShortVersionString string 0.1-gpt55' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 1' "$APP/Contents/Info.plist" 2>/dev/null || /usr/libexec/PlistBuddy -c 'Add :CFBundleVersion string 1' "$APP/Contents/Info.plist"

RESOURCE_BUNDLE="$(find "$ROOT/.build/arm64-apple-macosx/release" -maxdepth 1 -type d -name 'ClickyCheck_ClickyCheck.bundle' -print -quit)"
if [[ -n "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
fi
SPARKLE_FRAMEWORK="$(find "$ROOT/.build/arm64-apple-macosx/release" -maxdepth 1 -type d -name 'Sparkle.framework' -print -quit)"
if [[ -n "$SPARKLE_FRAMEWORK" ]]; then
  cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/"
fi

# SwiftPM's executable may only contain @loader_path; an app bundle needs this
# rpath so @rpath/Sparkle.framework resolves from Contents/Frameworks.
install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP/Contents/MacOS/Clicky" 2>/dev/null || true
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null
printf 'Installed %s\n' "$APP"
