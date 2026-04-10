#!/bin/bash
set -euo pipefail

# Add Homebrew to PATH so create-dmg and gh are available in non-interactive shells
export PATH="/opt/homebrew/bin:$PATH"

# =============================================================================
# release.sh — Automates the full release pipeline for makesomething
#
# What it does (in order):
#   1. Auto-detects version + build from the latest GitHub Release
#   2. Archives the app via xcodebuild
#   3. Exports a signed + notarized .app
#   4. Wraps it in a DMG with the drag-to-Applications background
#   5. Notarizes the DMG with Apple (so Gatekeeper won't block it)
#   6. Signs the DMG with your Sparkle EdDSA key
#   7. Generates/updates appcast.xml automatically
#   8. Creates a GitHub Release with the DMG attached
#   9. Pushes the updated appcast.xml to the releases repo (makesomething-mac-app)
#
# Usage:
#   ./scripts/release.sh              Auto-bumps: 1.5 → 1.6, build 6 → 7
#   ./scripts/release.sh 2.0          Sets marketing version to 2.0, auto-bumps build
#   ./scripts/release.sh 2.0 10       Sets both marketing version and build number
#
# Prerequisites (one-time setup):
#   - Xcode with your Developer ID signing certificate
#   - `brew install create-dmg gh`
#   - `gh auth login` (GitHub CLI authenticated)
#   - Sparkle EdDSA key in your Keychain (already generated)
#   - `xcrun notarytool store-credentials "AC_PASSWORD"` (Apple notarization credentials)
# =============================================================================

# ── Configuration ────────────────────────────────────────────────────────────

SCHEME="leanring-buddy"
APP_NAME="makesomething"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_DIR="${BUILD_DIR}/export"
DMG_OUTPUT_DIR="${BUILD_DIR}/dmg"
RELEASES_DIR="${PROJECT_DIR}/releases"  # where generate_appcast reads DMGs from
DMG_BACKGROUND="${PROJECT_DIR}/dmg-background.png"

GITHUB_REPO="julianjear/makesomething-mac-app"

# Sparkle tools (auto-discovered from Xcode's SPM cache)
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData/leanring-buddy*/SourcePackages/artifacts/sparkle/Sparkle/bin -maxdepth 0 2>/dev/null | head -1)

if [ -z "$SPARKLE_BIN" ]; then
    echo "❌ Sparkle tools not found. Build the project in Xcode first so SPM downloads Sparkle."
    exit 1
fi

# ── Auto-detect version from latest GitHub Release ──────────────────────────
# Fetches the latest release tag (e.g. "v1.5") and build number from GitHub.
# If no arguments are provided, bumps the minor version by 0.1 and build by 1.
# You can override either or both by passing arguments.

echo "🔍 Checking latest release on GitHub..."

LATEST_TAG=$(gh release view --repo "${GITHUB_REPO}" --json tagName --jq '.tagName' 2>/dev/null || echo "")

if [ -n "$LATEST_TAG" ]; then
    # Strip the "v" prefix to get the version number (e.g. "v1.5" → "1.5")
    LATEST_VERSION="${LATEST_TAG#v}"

    # Get the build number from the latest release's app bundle inside the DMG.
    # We download just the release metadata (not the DMG) and parse the body/notes,
    # but the simplest reliable approach is to track it from the GitHub release title
    # or from a known incrementing sequence. We use the GitHub API to get asset info
    # and derive the build number from the release list count.
    LATEST_BUILD=$(gh release list --repo "${GITHUB_REPO}" --json tagName --jq 'length' 2>/dev/null || echo "0")

    echo "   Latest release: ${LATEST_TAG} (build ${LATEST_BUILD})"
else
    LATEST_VERSION="0.0"
    LATEST_BUILD=0
    echo "   No previous releases found — starting from scratch"
fi

# Determine the next marketing version: bump minor by 0.1
# e.g. "1.5" → "1.6", "2.9" → "3.0" (carries over)
if [ $# -ge 1 ]; then
    MARKETING_VERSION="$1"
else
    MAJOR=$(echo "$LATEST_VERSION" | cut -d. -f1)
    MINOR=$(echo "$LATEST_VERSION" | cut -d. -f2)
    NEXT_MINOR=$((MINOR + 1))
    if [ "$NEXT_MINOR" -ge 10 ]; then
        MAJOR=$((MAJOR + 1))
        NEXT_MINOR=0
    fi
    MARKETING_VERSION="${MAJOR}.${NEXT_MINOR}"
fi

# Determine the next build number: always increment by 1
if [ $# -ge 2 ]; then
    BUILD_NUMBER="$2"
else
    BUILD_NUMBER=$((LATEST_BUILD + 1))
fi

DMG_FILENAME="${APP_NAME}.dmg"
TAG="v${MARKETING_VERSION}"

# ── Safety checks ────────────────────────────────────────────────────────────

# Check if this tag already exists on GitHub to prevent accidental duplicates
if gh release view "${TAG}" --repo "${GITHUB_REPO}" &>/dev/null; then
    echo ""
    echo "❌ Release ${TAG} already exists on GitHub!"
    echo "   https://github.com/${GITHUB_REPO}/releases/tag/${TAG}"
    echo ""
    echo "   To release a new version, either:"
    echo "     • Run without arguments to auto-bump: ./scripts/release.sh"
    echo "     • Specify a higher version: ./scripts/release.sh $(echo "${MARKETING_VERSION} + 0.1" | bc)"
    echo "     • Delete the existing release first: gh release delete ${TAG} --repo ${GITHUB_REPO} --yes"
    exit 1
fi

echo ""
echo "🚀 Releasing ${APP_NAME} v${MARKETING_VERSION} (build ${BUILD_NUMBER})"
echo "   Previous: ${LATEST_TAG:-none}"
echo ""

# Confirm with the user before proceeding
read -p "   Proceed? (y/N) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "   Aborted."
    exit 0
fi
echo ""

# ── Step 1: Clean build directory ────────────────────────────────────────────

echo "🧹 Cleaning build directory and stale DMGs..."
rm -rf "${BUILD_DIR}"
# Remove any leftover temp DMGs from create-dmg (rw.*.dmg) and the previous
# same-named DMG so create-dmg and generate_appcast don't choke on duplicates.
rm -f "${RELEASES_DIR}"/rw.*.dmg "${RELEASES_DIR}/${DMG_FILENAME}"
mkdir -p "${BUILD_DIR}" "${EXPORT_DIR}" "${DMG_OUTPUT_DIR}" "${RELEASES_DIR}"

# ── Step 2: Archive ──────────────────────────────────────────────────────────

echo "📦 Archiving..."
xcodebuild archive \
    -scheme "${SCHEME}" \
    -archivePath "${ARCHIVE_PATH}" \
    MARKETING_VERSION="${MARKETING_VERSION}" \
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
    2>&1 | tail -5

echo "✅ Archive created"

# ── Step 3: Export (signed + notarized) ──────────────────────────────────────

# Create an export options plist for Developer ID distribution.
# This tells xcodebuild to sign with your Developer ID certificate
# and submit to Apple for notarization automatically.
EXPORT_OPTIONS="${BUILD_DIR}/ExportOptions.plist"
cat > "${EXPORT_OPTIONS}" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST

echo "📤 Exporting (signing + notarizing — this may take a few minutes)..."
xcodebuild -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportPath "${EXPORT_DIR}" \
    -exportOptionsPlist "${EXPORT_OPTIONS}" \
    2>&1 | tail -5

echo "✅ Export complete (signed + notarized)"

# ── Step 4: Create DMG ──────────────────────────────────────────────────────

DMG_PATH="${RELEASES_DIR}/${DMG_FILENAME}"

echo "💿 Creating DMG..."
create-dmg \
    --volname "${APP_NAME}" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 100 \
    --icon "${APP_NAME}.app" 160 195 \
    --app-drop-link 500 195 \
    --background "${DMG_BACKGROUND}" \
    "${DMG_PATH}" \
    "${EXPORT_DIR}/${APP_NAME}.app" \
    2>&1 | tail -3

echo "✅ DMG created: ${DMG_PATH}"

# ── Step 5: Notarize the DMG ─────────────────────────────────────────────────
# The .app inside the DMG is already signed with Developer ID, but the DMG
# itself needs to be submitted to Apple for notarization so Gatekeeper
# allows users to open it without the "Apple could not verify" warning.
# Requires stored credentials: xcrun notarytool store-credentials "AC_PASSWORD"

echo "🔏 Notarizing DMG with Apple (this may take a few minutes)..."
xcrun notarytool submit "${DMG_PATH}" \
    --keychain-profile "AC_PASSWORD" \
    --wait

echo "📎 Stapling notarization ticket to DMG..."
xcrun stapler staple "${DMG_PATH}"

echo "✅ DMG notarized and stapled"

# ── Step 6: Sign DMG with Sparkle EdDSA key ─────────────────────────────────

echo "🔐 Signing DMG with Sparkle EdDSA key..."
"${SPARKLE_BIN}/sign_update" "${DMG_PATH}"

# ── Step 7: Generate / update appcast.xml ────────────────────────────────────
# generate_appcast reads all DMGs in the releases/ directory, extracts version
# info from the app bundle inside each DMG, signs with your EdDSA key, and
# produces appcast.xml. The --download-url-prefix tells it where users will
# actually download the DMG from (GitHub Releases).

echo "📡 Generating appcast.xml..."
"${SPARKLE_BIN}/generate_appcast" \
    --download-url-prefix "https://github.com/${GITHUB_REPO}/releases/download/${TAG}/" \
    -o "${PROJECT_DIR}/appcast.xml" \
    "${RELEASES_DIR}"

echo "✅ appcast.xml updated"

# ── Step 8: Create GitHub Release ────────────────────────────────────────────
# Create the release first so the DMG download URL is live before we push the
# appcast that references it.

echo "🏷️  Creating GitHub Release ${TAG}..."
gh release create "${TAG}" "${DMG_PATH}" \
    --repo "${GITHUB_REPO}" \
    --title "v${MARKETING_VERSION}" \
    --notes "makesomething v${MARKETING_VERSION}" \
    --latest

# ── Step 9: Push appcast.xml to the releases repo ───────────────────────────
# The appcast lives in makesomething-mac-app (the releases repo), not in the
# source code repo. We clone it to a temp dir, copy the new appcast, and push.

echo "📝 Pushing appcast.xml to ${GITHUB_REPO}..."
RELEASES_REPO_DIR=$(mktemp -d)
git clone --depth 1 "https://github.com/${GITHUB_REPO}.git" "${RELEASES_REPO_DIR}" 2>&1 | tail -2
cp "${PROJECT_DIR}/appcast.xml" "${RELEASES_REPO_DIR}/appcast.xml"
cd "${RELEASES_REPO_DIR}"
git add appcast.xml
git commit -m "Update appcast.xml for v${MARKETING_VERSION}" || echo "   (no changes to commit)"
git push || echo "   (push failed — you may need to push manually)"
cd "${PROJECT_DIR}"
rm -rf "${RELEASES_REPO_DIR}"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "✅ Release v${MARKETING_VERSION} (build ${BUILD_NUMBER}) complete!"
echo ""
echo "   DMG:      ${DMG_PATH}"
echo "   Appcast:  ${PROJECT_DIR}/appcast.xml"
echo "   Release:  https://github.com/${GITHUB_REPO}/releases/tag/${TAG}"
echo ""
echo "   Download URL (always latest):"
echo "   https://github.com/${GITHUB_REPO}/releases/latest/download/${DMG_FILENAME}"
echo "═══════════════════════════════════════════════════════════════"
