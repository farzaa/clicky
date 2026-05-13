#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${project_root}"

if [[ "${DOT_RELEASE:-}" == "1" ]]; then
  echo "release boundary check skipped because DOT_RELEASE=1"
  exit 0
fi

latest_commit_subject="$(git log -1 --pretty=%s 2>/dev/null || true)"
if [[ "${latest_commit_subject}" =~ ^Update\ appcast\.xml\ for\ v[0-9] ]]; then
  echo "release boundary check skipped for appcast release commit"
  exit 0
fi

changed_files="$(
  {
    if [[ -n "${GITHUB_BASE_REF:-}" ]]; then
      git diff --name-only "origin/${GITHUB_BASE_REF}...HEAD" 2>/dev/null || true
    elif git rev-parse --verify HEAD^ >/dev/null 2>&1; then
      git diff --name-only HEAD^...HEAD 2>/dev/null || true
    fi
    git diff --name-only --cached
    git diff --name-only
    git ls-files --others --exclude-standard
  } | sort -u
)"

protected_appcast_paths=(
  "appcast.xml"
  "website/dot/appcast.xml"
)

for protected_path in "${protected_appcast_paths[@]}"; do
  if printf '%s\n' "${changed_files}" | grep -Fxq "${protected_path}"; then
    if [[ "${protected_path}" == "website/dot/appcast.xml" ]] \
      && ! printf '%s\n' "${changed_files}" | grep -Fxq "appcast.xml" \
      && cmp -s appcast.xml website/dot/appcast.xml; then
      continue
    fi
    echo "error: ${protected_path} changed outside an explicit release."
    echo "Set DOT_RELEASE=1 only when intentionally publishing a Sparkle update."
    exit 1
  fi
done

expected_download_url='downloadDmgURL: "https://github.com/Clamepending/dot/releases/latest/download/Dot.dmg"'
if ! grep -Fq "${expected_download_url}" website/dot/config.js; then
  echo "error: website/dot/config.js no longer points at the stable latest Dot.dmg download URL."
  echo "Expected: ${expected_download_url}"
  exit 1
fi

echo "release boundary check passed"
