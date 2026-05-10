#!/usr/bin/env bash
set -euo pipefail

line_count="${1:-200}"
log_file="${HOME}/Library/Logs/Dot/dot.log"

mkdir -p "$(dirname "${log_file}")"
touch "${log_file}"

echo "Tailing ${log_file}"
tail -n "${line_count}" -F "${log_file}"
