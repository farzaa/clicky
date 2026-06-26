#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKER_DIR="${PROJECT_DIR}/worker"
WRANGLER="${WORKER_DIR}/wrangler.toml"
PACKAGE_JSON="${WORKER_DIR}/package.json"
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

error() {
    errors=$((errors + 1))
    echo "ERROR: $*"
}

ok() {
    echo "OK:    $*"
}

require_file() {
    if [ -f "$1" ]; then
        ok "Found ${1#"${PROJECT_DIR}/"}"
    else
        error "Missing ${1#"${PROJECT_DIR}/"}"
    fi
}

toml_string() {
    local key="$1"
    awk -F '=' -v search_key="${key}" '
        $1 ~ "^[[:space:]]*" search_key "[[:space:]]*$" {
            value = $2
            sub(/^[[:space:]]*"/, "", value)
            sub(/"[[:space:]]*$/, "", value)
            print value
            exit
        }
    ' "${WRANGLER}"
}

is_placeholder_url() {
    local value="$1"

    [[ "${value}" == *example.com* ]] \
        || [[ "${value}" == *.example* ]] \
        || [[ "${value}" == *yourdomain.com* ]] \
        || [[ "${value}" == *.test* ]] \
        || [[ "${value}" == *.invalid* ]] \
        || [[ "${value}" == *localhost* ]] \
        || [[ "${value}" == *"127.0.0.1"* ]] \
        || [[ "${value}" == *"10.0.0."* ]] \
        || [[ "${value}" == *"192.168."* ]]
}

check_required_secret_manifest() {
    local missing=0
    for secret_name in "${REQUIRED_SECRETS[@]}"; do
        if rg -q "wrangler secret put ${secret_name}" "${PROJECT_DIR}/README.md" "${PROJECT_DIR}/scripts/README.md" "${PROJECT_DIR}/AGENTS.md"; then
            ok "Required Worker secret is documented: ${secret_name}"
        else
            error "Required Worker secret is not documented: ${secret_name}"
            missing=1
        fi
    done

    if [ "${missing}" -eq 0 ]; then
        ok "Worker required secret manifest is complete"
    fi
}

check_url_config() {
    local key="$1"
    local value

    value="$(toml_string "${key}")"
    if [ -z "${value}" ]; then
        error "${key} is missing"
    elif is_placeholder_url "${value}"; then
        error "${key} points to a placeholder or local host"
    elif [[ "${value}" != https://* ]]; then
        error "${key} must use https://"
    else
        ok "${key} is production-shaped"
    fi
}

check_d1_database_id() {
    local value
    value="$(toml_string database_id)"

    if [ -z "${value}" ]; then
        error "D1 database_id is missing"
    elif [ "${value}" = "replace-with-cloudflare-d1-database-id" ]; then
        error "D1 database_id is still a placeholder"
    elif [[ ! "${value}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        error "D1 database_id must be UUID-shaped"
    elif [ "${value}" = "00000000-0000-0000-0000-000000000000" ]; then
        error "D1 database_id must not be the all-zero UUID"
    else
        ok "D1 database_id is production-shaped"
    fi
}

check_migrations() {
    local migration_count

    migration_count="$(find "${WORKER_DIR}/migrations" -maxdepth 1 -name "*.sql" -type f | wc -l | tr -d ' ')"
    if [ "${migration_count}" -gt 0 ]; then
        ok "D1 migrations are present (${migration_count})"
    else
        error "D1 migrations are missing"
    fi

    if find "${WORKER_DIR}/migrations" -maxdepth 1 -name "*.sql" -type f | sort | awk '
        BEGIN { previous = "" }
        {
            current = $0
            sub(/^.*\//, "", current)
            prefix = substr(current, 1, 4)
            if (prefix !~ /^[0-9][0-9][0-9][0-9]$/) {
                bad = 1
            }
            if (previous != "" && prefix <= previous) {
                bad = 1
            }
            previous = prefix
        }
        END { exit bad ? 1 : 0 }
    '; then
        ok "D1 migration filenames are ordered and numeric"
    else
        error "D1 migration filenames must start with increasing numeric prefixes"
    fi
}

check_package_scripts() {
    if rg -q '"check": "npm run typegen:check && npm run typecheck && npm run smoke"' "${PACKAGE_JSON}"; then
        ok "Worker check script verifies generated types, typecheck, and smoke"
    else
        error "Worker check script must verify generated types, typecheck, and smoke"
    fi

    if rg -q '"typegen": "WRANGLER_LOG_PATH=.* wrangler types"' "${PACKAGE_JSON}" \
        && rg -q '"typegen:check": "WRANGLER_LOG_PATH=.* wrangler types --check"' "${PACKAGE_JSON}"; then
        ok "Worker typegen scripts keep Wrangler bindings in sync"
    else
        error "Worker typegen scripts are missing"
    fi

    if rg -q '"dry-run": "wrangler deploy --dry-run --outdir /tmp/spider-worker-dry-run"' "${PACKAGE_JSON}"; then
        ok "Worker dry-run deploy script is available"
    else
        error "Worker dry-run deploy script is missing"
    fi
}

echo "Spider Worker deploy preflight"
echo

require_file "${WRANGLER}"
require_file "${PACKAGE_JSON}"
require_file "${WORKER_DIR}/src/index.ts"
require_file "${WORKER_DIR}/worker-configuration.d.ts"
require_file "${WORKER_DIR}/tsconfig.json"
require_file "${WORKER_DIR}/tests/smoke-worker.mjs"

echo
echo "Production config"
check_url_config APP_LOGIN_CONFIRM_URL
check_url_config STRIPE_SUCCESS_URL
check_url_config STRIPE_CANCEL_URL
check_d1_database_id

echo
echo "Secrets"
check_required_secret_manifest

echo
echo "Migrations"
check_migrations

echo
echo "Package scripts"
check_package_scripts

echo
if [ "${errors}" -gt 0 ]; then
    echo "Worker deploy preflight failed: ${errors} error(s)."
    exit 1
fi

echo "Worker deploy preflight passed."
