#!/usr/bin/env bash
set -euo pipefail

# Builds and installs the local developer app without xcodebuild. This is useful
# on machines with only the Apple command line tools installed, and avoids
# disturbing macOS TCC permissions through terminal xcodebuild runs.

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_directory="${project_root}/leanring-buddy"
build_directory="${project_root}/build"
app_name="Clicky Dev"
bundle_identifier="com.mark.clicky-dev"
build_app_path="${build_directory}/${app_name}.app"
install_app_path="/Applications/${app_name}.app"
contents_directory="${build_app_path}/Contents"
macos_directory="${contents_directory}/MacOS"
resources_directory="${contents_directory}/Resources"
info_plist_path="${contents_directory}/Info.plist"
source_entitlements_path="${source_directory}/leanring-buddy.entitlements"
signing_entitlements_path="${source_entitlements_path}"
swift_target_architecture="$(uname -m)"
swift_target_triple="${swift_target_architecture}-apple-macosx14.2"
should_open_app=true
codesign_identity="${CLICKY_CODESIGN_IDENTITY:-}"

if [[ "${1:-}" == "--no-open" ]]; then
    should_open_app=false
fi

if [[ -z "${codesign_identity}" ]]; then
    codesign_identity="$(
        security find-identity -p codesigning -v 2>/dev/null \
            | awk -F '"' '/Developer ID Application:/ { print $2; exit }'
    )"
fi

if [[ -z "${codesign_identity}" ]]; then
    codesign_identity="-"
fi

set_plist_string_value() {
    local plist_key="$1"
    local plist_value="$2"

    if /usr/libexec/PlistBuddy -c "Print :${plist_key}" "${info_plist_path}" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :${plist_key} ${plist_value}" "${info_plist_path}"
    else
        /usr/libexec/PlistBuddy -c "Add :${plist_key} string ${plist_value}" "${info_plist_path}"
    fi
}

echo "Building ${app_name} for ${swift_target_triple}"
echo "Signing with ${codesign_identity}"

rm -rf "${build_app_path}"
mkdir -p "${macos_directory}" "${resources_directory}"

if [[ "${CLICKY_INCLUDE_RESTRICTED_ENTITLEMENTS:-}" != "1" ]]; then
    signing_entitlements_path="${build_directory}/${app_name}.local-dev.entitlements"
    cp "${source_entitlements_path}" "${signing_entitlements_path}"
    /usr/libexec/PlistBuddy \
        -c "Delete :com.apple.developer.persistent-content-capture" \
        "${signing_entitlements_path}" >/dev/null 2>&1 || true
    echo "Omitting restricted persistent-content-capture entitlement for local dev signing"
fi

xcrun swiftc \
    -swift-version 5 \
    -target "${swift_target_triple}" \
    -sdk "$(xcrun --show-sdk-path)" \
    -O \
    -emit-executable \
    "${source_directory}"/*.swift \
    -o "${macos_directory}/${app_name}"

cp "${source_directory}/Info.plist" "${info_plist_path}"
set_plist_string_value "CFBundleExecutable" "${app_name}"
set_plist_string_value "CFBundleIdentifier" "${bundle_identifier}"
set_plist_string_value "CFBundleName" "${app_name}"
set_plist_string_value "CFBundleDisplayName" "${app_name}"
set_plist_string_value "CFBundlePackageType" "APPL"
set_plist_string_value "CFBundleShortVersionString" "1.0"
set_plist_string_value "CFBundleVersion" "1"
set_plist_string_value "LSMinimumSystemVersion" "14.2"

find "${source_directory}" -maxdepth 1 -type f \( \
    -name "*.mp3" -o \
    -name "*.png" -o \
    -name "*.jpg" \
\) -exec cp {} "${resources_directory}/" \;

plutil -lint "${info_plist_path}" >/dev/null

codesign \
    --force \
    --deep \
    --timestamp=none \
    --sign "${codesign_identity}" \
    --entitlements "${signing_entitlements_path}" \
    "${build_app_path}" >/dev/null

codesign --verify --deep --strict --verbose=2 "${build_app_path}"

osascript -e "tell application id \"${bundle_identifier}\" to quit" >/dev/null 2>&1 || true

rm -rf "${install_app_path}"
ditto "${build_app_path}" "${install_app_path}"

if [[ "${should_open_app}" == true ]]; then
    open "${install_app_path}"
fi

echo "Installed ${install_app_path}"
