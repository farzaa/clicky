#!/usr/bin/env bash
# Always kill the previous menu-bar instance, then build & run (use after code changes).
set -euo pipefail
cd "$(dirname "$0")"
killall DebilMac 2>/dev/null || true
exec swift run
