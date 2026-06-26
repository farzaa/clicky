#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKER_DIR="${PROJECT_DIR}/worker"
OUTDIR="${TMPDIR:-/tmp}/spider-worker-remote-dry-run"
WRANGLER_LOG_DIR="${TMPDIR:-/tmp}/spider-wrangler-logs"
REQUIRED_SECRETS=(
    OPENAI_API_KEY
    EMAIL_HASH_SECRET
    RESEND_API_KEY
    MAGIC_LINK_FROM
    STRIPE_SECRET_KEY
    STRIPE_PRICE_ID
    STRIPE_WEBHOOK_SECRET
)

errors=0
wrangler_authenticated=0

error() {
    errors=$((errors + 1))
    echo "ERROR: $*"
}

ok() {
    echo "OK:    $*"
}

run_capture() {
    local output_path="$1"
    shift

    mkdir -p "${WRANGLER_LOG_DIR}"
    set +e
    (cd "${WORKER_DIR}" && WRANGLER_LOG_PATH="${WRANGLER_LOG_DIR}" "$@") >"${output_path}" 2>&1
    local status=$?
    set -e

    return "${status}"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || error "Missing required command: $1"
}

check_wrangler_version() {
    local output_path="${TMPDIR:-/tmp}/spider-wrangler-version.txt"

    if run_capture "${output_path}" npx wrangler --version; then
        local version
        version="$(tr -d '\r\n' < "${output_path}")"
        if [[ "${version}" == 4.* ]]; then
            ok "Wrangler ${version} is installed"
        else
            error "Wrangler v4.x is required; found ${version}"
        fi
    else
        error "Could not read Wrangler version"
    fi
}

check_auth() {
    local output_path="${TMPDIR:-/tmp}/spider-wrangler-whoami.txt"

    if run_capture "${output_path}" npx wrangler whoami; then
        wrangler_authenticated=1
        ok "Wrangler is authenticated"
    else
        error "Wrangler is not authenticated. Run wrangler login or set CLOUDFLARE_API_TOKEN."
    fi
}

check_remote_secrets() {
    local output_path="${TMPDIR:-/tmp}/spider-wrangler-secrets.json"

    if ! run_capture "${output_path}" npx wrangler secret list --format json; then
        error "Could not list remote Worker secrets"
        return
    fi

    for secret_name in "${REQUIRED_SECRETS[@]}"; do
        if node - "${output_path}" "${secret_name}" <<'NODE'
const fs = require("fs");
const [path, expected] = process.argv.slice(2);

let payload;
try {
  payload = JSON.parse(fs.readFileSync(path, "utf8"));
} catch {
  process.exit(2);
}

const entries = Array.isArray(payload) ? payload : [];
const names = entries
  .map((entry) => entry && (entry.name || entry.key))
  .filter((name) => typeof name === "string");

process.exit(names.includes(expected) ? 0 : 1);
NODE
        then
            ok "Remote Worker secret exists: ${secret_name}"
        else
            error "Remote Worker secret is missing: ${secret_name}"
        fi
    done
}

check_remote_d1_migrations() {
    local output_path="${TMPDIR:-/tmp}/spider-d1-migrations-remote.txt"

    if ! run_capture "${output_path}" npx wrangler d1 migrations list DB --remote; then
        error "Could not list remote D1 migrations"
        return
    fi

    local unapplied=0
    while IFS= read -r migration_path; do
        local migration_name
        migration_name="$(basename "${migration_path}")"
        if rg -q --fixed-strings "${migration_name}" "${output_path}"; then
            error "Remote D1 migration is not applied: ${migration_name}"
            unapplied=1
        fi
    done < <(find "${WORKER_DIR}/migrations" -maxdepth 1 -name "*.sql" -type f | sort)

    if [ "${unapplied}" -eq 0 ]; then
        ok "Remote D1 has no unapplied local migrations"
    fi
}

check_deploy_dry_run() {
    local output_path="${TMPDIR:-/tmp}/spider-worker-deploy-dry-run.txt"

    rm -rf "${OUTDIR}"
    if run_capture "${output_path}" npx wrangler deploy --dry-run --outdir "${OUTDIR}" --strict; then
        ok "Worker deploy dry run passes in strict mode"
    else
        error "Worker deploy dry run failed"
    fi
}

echo "Spider Worker remote preflight"
echo

require_command node
require_command npx

check_wrangler_version
check_auth
if [ "${wrangler_authenticated}" -eq 1 ]; then
    check_remote_secrets
    check_remote_d1_migrations
else
    echo "SKIP:  Remote secret and D1 checks require Wrangler authentication"
fi
check_deploy_dry_run

echo
if [ "${errors}" -gt 0 ]; then
    echo "Worker remote preflight failed: ${errors} error(s)."
    exit 1
fi

echo "Worker remote preflight passed."
