#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_PATH="${1:-/tmp/spider-mission-pointer-preview.png}"
BUILD_DIR="${TMPDIR:-/tmp}/spider-mission-pointer-preview"
MODULE_CACHE="${TMPDIR:-/tmp}/spider-swift-module-cache"

mkdir -p "$BUILD_DIR" "$MODULE_CACHE" "$(dirname "$OUTPUT_PATH")"

xcrun swiftc \
  -parse-as-library \
  -module-cache-path "$MODULE_CACHE" \
  "$ROOT_DIR/scripts/render_mission_pointer_preview.swift" \
  "$ROOT_DIR/leanring-buddy/DesignSystem.swift" \
  "$ROOT_DIR/leanring-buddy/GuideClickTargetView.swift" \
  -o "$BUILD_DIR/render_mission_pointer_preview"

"$BUILD_DIR/render_mission_pointer_preview" "$OUTPUT_PATH"
echo "$OUTPUT_PATH"
