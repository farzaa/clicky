#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKER_DIR="${PROJECT_DIR}/worker"
CONFIG_DIR="${HOME}/Library/Application Support/Clicky"
CONFIG_PATH="${CONFIG_DIR}/proxy.json"

read -r -p "Worker base URL (no path, e.g. https://clicky-proxy.example.workers.dev): " WORKER_BASE_URL

if [[ ! "${WORKER_BASE_URL}" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?$ \
   && ! "${WORKER_BASE_URL}" =~ ^http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?/?$ ]]; then
    echo "Use an HTTPS Worker URL, or localhost over HTTP for local development. Do not include a path."
    exit 1
fi

WORKER_BASE_URL="${WORKER_BASE_URL%/}"

if [[ -f "${CONFIG_PATH}" ]]; then
    read -r -p "This replaces the existing Clicky Worker configuration. Continue? [y/N] " CONFIRM_REPLACE
    if [[ ! "${CONFIRM_REPLACE}" =~ ^[Yy]$ ]]; then
        echo "Configuration unchanged."
        exit 0
    fi
fi

TOKEN="$(openssl rand -hex 32)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clicky-proxy.XXXXXX")"
TOKEN_FILE="${TEMP_DIR}/token"
CONFIG_TEMP="${TEMP_DIR}/proxy.json"
trap 'rm -f "${TOKEN_FILE}" "${CONFIG_TEMP}"; rmdir "${TEMP_DIR}" 2>/dev/null || true' EXIT

umask 077
printf '%s' "${TOKEN}" > "${TOKEN_FILE}"

if [[ "${WORKER_BASE_URL}" == http://localhost* || "${WORKER_BASE_URL}" == http://127.0.0.1* ]]; then
    DEVELOPER_VARS_PATH="${WORKER_DIR}/.dev.vars"
    touch "${DEVELOPER_VARS_PATH}"
    chmod 600 "${DEVELOPER_VARS_PATH}"
    if grep -q '^CLICKY_PROXY_TOKEN=' "${DEVELOPER_VARS_PATH}"; then
        sed -i '' "s/^CLICKY_PROXY_TOKEN=.*/CLICKY_PROXY_TOKEN=${TOKEN}/" "${DEVELOPER_VARS_PATH}"
    else
        printf '\nCLICKY_PROXY_TOKEN=%s\n' "${TOKEN}" >> "${DEVELOPER_VARS_PATH}"
    fi
    echo "Local development token written to worker/.dev.vars."
else
    echo "Uploading the Worker authentication secret (Wrangler deploys the updated Worker)..."
    (cd "${WORKER_DIR}" && npx wrangler secret put CLICKY_PROXY_TOKEN < "${TOKEN_FILE}")
fi

swift "${SCRIPT_DIR}/store-proxy-token.swift" "${TOKEN_FILE}"

mkdir -p "${CONFIG_DIR}"
printf '{"workerBaseURL":"%s"}\n' "${WORKER_BASE_URL}" > "${CONFIG_TEMP}"
chmod 600 "${CONFIG_TEMP}"
mv "${CONFIG_TEMP}" "${CONFIG_PATH}"

echo "Clicky Worker configuration saved. Restart Clicky to use it."
