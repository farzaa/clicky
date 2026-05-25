#!/usr/bin/env bash
# Assert Clicky overlay accessibility identifiers via axcli (optional).
set -euo pipefail

IDENTIFIER="${1:-}"
TIMEOUT_SECONDS="${2:-15}"

if [[ -z "$IDENTIFIER" ]]; then
  echo "Usage: $0 <accessibility-identifier> [timeout_seconds]"
  exit 2
fi

if ! command -v axcli >/dev/null 2>&1; then
  echo "WARNING: axcli not installed — skipping overlay assertion for $IDENTIFIER"
  exit 0
fi

for _ in $(seq 1 "$TIMEOUT_SECONDS"); do
  if axcli find --identifier "$IDENTIFIER" >/dev/null 2>&1; then
    echo "PASS: found overlay element $IDENTIFIER"
    exit 0
  fi
  sleep 1
done

echo "FAIL: overlay element not found: $IDENTIFIER"
exit 1
