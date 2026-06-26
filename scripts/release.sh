#!/bin/bash
set -euo pipefail

# Spider release pipeline.
#
# This script is intentionally for manual release use only. The app captures
# screen/mic permissions, so ordinary Codex automation should not run archive or
# export commands as part of day-to-day validation.
#
# Usage:
#   SPIDER_RELEASE_REPO="owner/spider-mac-app" ./scripts/release.sh
#   SPIDER_RELEASE_REPO="owner/spider-mac-app" ./scripts/release.sh 1.0
#   SPIDER_RELEASE_REPO="owner/spider-mac-app" ./scripts/release.sh 1.0 42
#
# Optional environment:
#   SPIDER_NOTARY_PROFILE       Keychain profile for notarytool. Default: AC_PASSWORD
#   SPIDER_DEVELOPMENT_TEAM     Apple Developer Team ID passed to xcodebuild.
#   SPIDER_SPARKLE_BIN          Directory containing Sparkle sign_update/generate_appcast.
#   SPIDER_DRY_RUN=1            Validate config and print planned release, then exit.
#
# Before release, materialize production URLs and the D1 database id with:
#   bash scripts/configure_release.sh
# Then verify Cloudflare remote state with:
#   bash scripts/worker_remote_preflight.sh

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

readonly SCHEME="leanring-buddy"
readonly APP_NAME="Spider"
readonly PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly BUILD_DIR="${PROJECT_DIR}/build"
readonly ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
readonly EXPORT_DIR="${BUILD_DIR}/export"
readonly RELEASES_DIR="${PROJECT_DIR}/releases"
readonly DMG_BACKGROUND="${PROJECT_DIR}/dmg-background.png"
readonly NOTARY_PROFILE="${SPIDER_NOTARY_PROFILE:-AC_PASSWORD}"
readonly MINIMUM_SYSTEM_VERSION="14.0"
readonly GITHUB_REPO="${SPIDER_RELEASE_REPO:-}"
readonly SPARKLE_BIN="${SPIDER_SPARKLE_BIN:-$(find "${HOME}/Library/Developer/Xcode/DerivedData" -path "*/SourcePackages/artifacts/sparkle/Sparkle/bin" -type d 2>/dev/null | head -1)}"

usage() {
    cat <<USAGE
Usage:
  SPIDER_RELEASE_REPO="owner/spider-mac-app" ./scripts/release.sh [marketing-version] [build-number]

Examples:
  SPIDER_RELEASE_REPO="owner/spider-mac-app" ./scripts/release.sh
  SPIDER_RELEASE_REPO="owner/spider-mac-app" ./scripts/release.sh 1.0
  SPIDER_RELEASE_REPO="owner/spider-mac-app" ./scripts/release.sh 1.0 42

Environment:
  SPIDER_NOTARY_PROFILE       Keychain profile for notarytool. Default: AC_PASSWORD
  SPIDER_DEVELOPMENT_TEAM     Apple Developer Team ID for archive/export.
  SPIDER_SPARKLE_BIN          Path to Sparkle CLI tools.
  SPIDER_DRY_RUN=1            Validate config and print planned release.

Production config:
  Run scripts/configure_release.sh before release. It requires:
    SPIDER_APPCAST_URL
    SPIDER_WORKER_BASE_URL
    SPIDER_LOGIN_CONFIRM_URL
    SPIDER_STRIPE_SUCCESS_URL
    SPIDER_STRIPE_CANCEL_URL
    SPIDER_D1_DATABASE_ID

Remote Worker readiness:
  release.sh runs scripts/worker_remote_preflight.sh before archive/export.
  That requires Wrangler auth through wrangler login or CLOUDFLARE_API_TOKEN.
USAGE
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

require_file() {
    [ -f "$1" ] || fail "Missing required file: $1"
}

require_directory() {
    [ -d "$1" ] || fail "Missing required directory: $1"
}

require_clean_worktree() {
    if ! git -C "${PROJECT_DIR}" diff --quiet || ! git -C "${PROJECT_DIR}" diff --cached --quiet; then
        fail "Working tree has uncommitted changes. Release from a clean commit."
    fi
}

latest_release_tag() {
    gh release view --repo "${GITHUB_REPO}" --json tagName --jq ".tagName" 2>/dev/null || true
}

latest_release_count() {
    gh release list --repo "${GITHUB_REPO}" --json tagName --jq "length" 2>/dev/null || echo "0"
}

next_marketing_version() {
    local latest_version="$1"

    if [ $# -ge 2 ] && [ -n "$2" ]; then
        echo "$2"
        return
    fi

    local major minor
    major="$(echo "${latest_version}" | cut -d. -f1)"
    minor="$(echo "${latest_version}" | cut -d. -f2)"

    case "${major}.${minor}" in
        *[!0-9.]*|.*|*.)
            echo "0.1"
            return
            ;;
    esac

    minor=$((minor + 1))
    if [ "${minor}" -ge 10 ]; then
        major=$((major + 1))
        minor=0
    fi

    echo "${major}.${minor}"
}

write_export_options() {
    local output_path="$1"

    cat > "${output_path}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>destination</key>
    <string>export</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST
}

create_dmg() {
    local dmg_path="$1"

    create-dmg \
        --volname "${APP_NAME}" \
        --window-pos 200 120 \
        --window-size 660 400 \
        --icon-size 100 \
        --icon "${APP_NAME}.app" 160 195 \
        --app-drop-link 500 195 \
        --background "${DMG_BACKGROUND}" \
        "${dmg_path}" \
        "${EXPORT_DIR}/${APP_NAME}.app"
}

release_notes() {
    local marketing_version="$1"
    local build_number="$2"

    cat <<NOTES
Spider v${marketing_version}

Build: ${build_number}
Distribution: Developer ID signed, notarized DMG
NOTES
}

main() {
    if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
        usage
        exit 0
    fi

    [ -n "${GITHUB_REPO}" ] || fail "Set SPIDER_RELEASE_REPO to the GitHub releases repo, for example owner/spider-mac-app."
    require_command gh
    require_command git
    require_command xcodebuild
    require_command xcrun
    require_command create-dmg
    require_file "${DMG_BACKGROUND}"
    require_file "${PROJECT_DIR}/scripts/release_preflight.sh"
    require_file "${PROJECT_DIR}/scripts/worker_remote_preflight.sh"
    require_directory "${SPARKLE_BIN}"
    require_file "${SPARKLE_BIN}/sign_update"
    require_file "${SPARKLE_BIN}/generate_appcast"

    if [ "${SPIDER_SKIP_CLEAN_CHECK:-0}" != "1" ]; then
        require_clean_worktree
    fi

    echo "Running release preflight..."
    bash "${PROJECT_DIR}/scripts/release_preflight.sh"

    echo "Running remote Worker preflight..."
    bash "${PROJECT_DIR}/scripts/worker_remote_preflight.sh"

    local latest_tag latest_version release_count marketing_version build_number tag dmg_filename dmg_path export_options xcode_team_arg

    latest_tag="$(latest_release_tag)"
    if [ -n "${latest_tag}" ]; then
        latest_version="${latest_tag#v}"
        release_count="$(latest_release_count)"
    else
        latest_version="0.0"
        release_count="0"
    fi

    marketing_version="$(next_marketing_version "${latest_version}" "${1:-}")"
    build_number="${2:-$((release_count + 1))}"
    tag="v${marketing_version}"
    dmg_filename="${APP_NAME}.dmg"
    dmg_path="${RELEASES_DIR}/${dmg_filename}"
    export_options="${BUILD_DIR}/ExportOptions.plist"

    if gh release view "${tag}" --repo "${GITHUB_REPO}" >/dev/null 2>&1; then
        fail "Release ${tag} already exists at https://github.com/${GITHUB_REPO}/releases/tag/${tag}"
    fi

    cat <<SUMMARY
Spider release plan
  App:             ${APP_NAME}
  Scheme:          ${SCHEME}
  Version:         ${marketing_version}
  Build:           ${build_number}
  Previous tag:    ${latest_tag:-none}
  GitHub repo:     ${GITHUB_REPO}
  DMG:             ${dmg_path}
  Sparkle tools:   ${SPARKLE_BIN}
  Notary profile:  ${NOTARY_PROFILE}
SUMMARY

    if [ "${SPIDER_DRY_RUN:-0}" = "1" ]; then
        echo "Dry run complete. No archive, signing, notarization, upload, or git changes were performed."
        exit 0
    fi

    read -r -p "Proceed with Developer ID archive, notarized DMG, GitHub release, and appcast publish? (y/N) " reply
    case "${reply}" in
        y|Y|yes|YES) ;;
        *) echo "Aborted."; exit 0 ;;
    esac

    mkdir -p "${BUILD_DIR}" "${EXPORT_DIR}" "${RELEASES_DIR}"
    rm -rf "${ARCHIVE_PATH}" "${EXPORT_DIR:?}/${APP_NAME}.app"
    rm -f "${RELEASES_DIR}/rw."*.dmg "${dmg_path}"

    xcode_team_arg=()
    if [ -n "${SPIDER_DEVELOPMENT_TEAM:-}" ]; then
        xcode_team_arg=(DEVELOPMENT_TEAM="${SPIDER_DEVELOPMENT_TEAM}")
    fi

    echo "Archiving ${APP_NAME}..."
    xcodebuild archive \
        -scheme "${SCHEME}" \
        -archivePath "${ARCHIVE_PATH}" \
        MARKETING_VERSION="${marketing_version}" \
        CURRENT_PROJECT_VERSION="${build_number}" \
        "${xcode_team_arg[@]}"

    write_export_options "${export_options}"

    echo "Exporting Developer ID app..."
    xcodebuild -exportArchive \
        -archivePath "${ARCHIVE_PATH}" \
        -exportPath "${EXPORT_DIR}" \
        -exportOptionsPlist "${export_options}" \
        "${xcode_team_arg[@]}"

    echo "Creating DMG..."
    create_dmg "${dmg_path}"

    echo "Notarizing DMG..."
    xcrun notarytool submit "${dmg_path}" \
        --keychain-profile "${NOTARY_PROFILE}" \
        --wait

    echo "Stapling notarization ticket..."
    xcrun stapler staple "${dmg_path}"

    echo "Signing Sparkle update..."
    "${SPARKLE_BIN}/sign_update" "${dmg_path}"

    echo "Generating appcast..."
    "${SPARKLE_BIN}/generate_appcast" \
        --download-url-prefix "https://github.com/${GITHUB_REPO}/releases/download/${tag}/" \
        --minimum-system-version "${MINIMUM_SYSTEM_VERSION}" \
        -o "${PROJECT_DIR}/appcast.xml" \
        "${RELEASES_DIR}"

    echo "Creating GitHub release..."
    gh release create "${tag}" "${dmg_path}" \
        --repo "${GITHUB_REPO}" \
        --title "Spider ${marketing_version}" \
        --notes "$(release_notes "${marketing_version}" "${build_number}")" \
        --latest

    echo
    echo "Release complete"
    echo "  DMG:      ${dmg_path}"
    echo "  Appcast:  ${PROJECT_DIR}/appcast.xml"
    echo "  Release:  https://github.com/${GITHUB_REPO}/releases/tag/${tag}"
    echo "  Latest:   https://github.com/${GITHUB_REPO}/releases/latest/download/${dmg_filename}"
}

main "$@"
