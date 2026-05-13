#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${project_root}"

appcast_url="${DOT_APPCAST_URL:-$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' leanring-buddy/Info.plist)}"
latest_download_url="${DOT_LATEST_DOWNLOAD_URL:-https://github.com/Clamepending/dot/releases/latest/download/Dot.dmg}"
expected_version="${1:-${DOT_EXPECTED_VERSION:-}}"
expected_tag="${DOT_EXPECTED_TAG:-${expected_version:+v${expected_version}}}"

temporary_directory="$(mktemp -d)"
trap 'rm -rf "${temporary_directory}"' EXIT

appcast_file="${temporary_directory}/appcast.xml"
headers_file="${temporary_directory}/latest.headers"

echo "checking appcast: ${appcast_url}"
curl -fsSL "${appcast_url}" -o "${appcast_file}"

appcast_version="$(
  sed -n 's#.*<sparkle:shortVersionString>\([^<]*\)</sparkle:shortVersionString>.*#\1#p' "${appcast_file}" \
    | head -1
)"
appcast_enclosure_url="$(
  sed -n 's#.*<enclosure url="\([^"]*\)".*#\1#p' "${appcast_file}" \
    | head -1
)"

if [[ -z "${appcast_version}" || -z "${appcast_enclosure_url}" ]]; then
  echo "error: could not parse newest version/enclosure from appcast"
  exit 1
fi

echo "appcast newest version: ${appcast_version}"
echo "appcast newest enclosure: ${appcast_enclosure_url}"

if [[ -n "${expected_version}" && "${appcast_version}" != "${expected_version}" ]]; then
  echo "error: expected appcast version ${expected_version}, got ${appcast_version}"
  exit 1
fi

echo "checking latest download redirect: ${latest_download_url}"
curl -fsSIL "${latest_download_url}" -o "${headers_file}"
if [[ -n "${expected_tag}" ]] && ! grep -Eiq "location: .*\/releases\/download\/${expected_tag//./\\.}\/Dot\.dmg" "${headers_file}"; then
  echo "error: latest download did not redirect through ${expected_tag}"
  cat "${headers_file}"
  exit 1
fi

content_length="$(
  awk 'BEGIN { IGNORECASE=1 } /^content-length:/ { value=$2 } END { gsub("\r", "", value); print value }' "${headers_file}"
)"
if [[ -z "${content_length}" || "${content_length}" -le 0 ]]; then
  echo "error: latest download response did not report a positive content length"
  cat "${headers_file}"
  exit 1
fi

echo "latest download content length: ${content_length}"

if command -v gh >/dev/null 2>&1; then
  release_json="$(gh api repos/Clamepending/dot/releases/latest)"
  release_tag="$(printf '%s' "${release_json}" | sed -n 's/.*"tag_name":"\([^"]*\)".*/\1/p')"
  if [[ -n "${expected_tag}" && "${release_tag}" != "${expected_tag}" ]]; then
    echo "error: GitHub latest release is ${release_tag}, expected ${expected_tag}"
    exit 1
  fi
  echo "GitHub latest release: ${release_tag}"
fi

local_app_plist="/Applications/Dot.app/Contents/Info.plist"
if [[ -f "${local_app_plist}" ]]; then
  local_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${local_app_plist}")"
  local_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${local_app_plist}")"
  echo "local /Applications/Dot.app version: ${local_version} (${local_build})"
else
  echo "local /Applications/Dot.app not installed; skipped local version check"
fi

echo "release smoke check passed"
