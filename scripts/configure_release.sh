#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INFO_PLIST="${PROJECT_DIR}/leanring-buddy/Info.plist"
WRANGLER="${PROJECT_DIR}/worker/wrangler.toml"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

required_env() {
    local name="$1"
    local value="${!name:-}"

    if [ -z "${value}" ]; then
        fail "Set ${name}."
    fi

    printf "%s" "${value}"
}

validate_url() {
    local value="$1"
    local label="$2"
    local mode="$3"

    node - "${value}" "${label}" "${mode}" <<'NODE'
const [value, label, mode] = process.argv.slice(2);

function fail(message) {
  console.error(`ERROR: ${message}`);
  process.exit(1);
}

let url;
try {
  url = new URL(value);
} catch {
  fail(`${label} must be a valid URL.`);
}

if (url.protocol !== "https:") {
  fail(`${label} must use https://.`);
}
const hostname = url.hostname.toLowerCase();
if (
  hostname.endsWith("example.com")
  || hostname.endsWith(".example")
  || hostname.endsWith("yourdomain.com")
  || hostname.endsWith(".test")
  || hostname.endsWith(".invalid")
  || hostname === "localhost"
  || hostname.endsWith(".localhost")
  || /^(127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[0-1])\.)/.test(hostname)
) {
  fail(`${label} must not point to a placeholder or local host.`);
}
if (url.username || url.password) {
  fail(`${label} must not include credentials.`);
}
if (url.port) {
  fail(`${label} must not include an explicit port.`);
}
if (url.hash) {
  fail(`${label} must not include a URL fragment.`);
}

if (mode === "origin") {
  if (url.pathname !== "/" || url.search) {
    fail(`${label} must be a clean origin URL.`);
  }
}

if (mode === "login-confirm") {
  if (url.pathname !== "/auth/login/confirm" || url.search) {
    fail(`${label} must point to /auth/login/confirm without query parameters.`);
  }
}

if (mode === "appcast") {
  if (!url.pathname.endsWith(".xml") || url.search) {
    fail(`${label} must point to an appcast .xml URL without query parameters.`);
  }
}

if (mode === "page" && url.search) {
  fail(`${label} must not include query parameters.`);
}
NODE
}

validate_d1_database_id() {
    local value="$1"

    if [[ ! "${value}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
        fail "SPIDER_D1_DATABASE_ID must be a Cloudflare D1 database UUID."
    fi
    if [ "${value}" = "00000000-0000-0000-0000-000000000000" ]; then
        fail "SPIDER_D1_DATABASE_ID must not be an all-zero placeholder UUID."
    fi
}

set_plist_string() {
    local key="$1"
    local value="$2"

    if /usr/libexec/PlistBuddy -c "Print :${key}" "${INFO_PLIST}" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "${INFO_PLIST}"
    else
        /usr/libexec/PlistBuddy -c "Add :${key} string ${value}" "${INFO_PLIST}"
    fi
}

set_toml_string() {
    local key="$1"
    local value="$2"

    node - "${WRANGLER}" "${key}" "${value}" <<'NODE'
const fs = require("fs");
const [path, key, value] = process.argv.slice(2);
const escapedKey = key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const pattern = new RegExp(`^([ \t]*${escapedKey}[ \t]*=[ \t]*)".*"$`, "m");
const content = fs.readFileSync(path, "utf8");

if (!pattern.test(content)) {
  console.error(`ERROR: Could not find ${key} in ${path}.`);
  process.exit(1);
}

fs.writeFileSync(path, content.replace(pattern, `$1${JSON.stringify(value)}`));
NODE
}

appcast_url="$(required_env SPIDER_APPCAST_URL)"
worker_base_url="$(required_env SPIDER_WORKER_BASE_URL)"
login_confirm_url="$(required_env SPIDER_LOGIN_CONFIRM_URL)"
stripe_success_url="$(required_env SPIDER_STRIPE_SUCCESS_URL)"
stripe_cancel_url="$(required_env SPIDER_STRIPE_CANCEL_URL)"
d1_database_id="$(required_env SPIDER_D1_DATABASE_ID)"

validate_url "${appcast_url}" "SPIDER_APPCAST_URL" "appcast"
validate_url "${worker_base_url}" "SPIDER_WORKER_BASE_URL" "origin"
validate_url "${login_confirm_url}" "SPIDER_LOGIN_CONFIRM_URL" "login-confirm"
validate_url "${stripe_success_url}" "SPIDER_STRIPE_SUCCESS_URL" "page"
validate_url "${stripe_cancel_url}" "SPIDER_STRIPE_CANCEL_URL" "page"
validate_d1_database_id "${d1_database_id}"

if [ "${SPIDER_CONFIGURE_DRY_RUN:-0}" = "1" ]; then
    echo "Spider release configuration dry run passed."
    exit 0
fi

set_plist_string "SUFeedURL" "${appcast_url}"
set_plist_string "SpiderWorkerBaseURL" "${worker_base_url}"
set_toml_string "APP_LOGIN_CONFIRM_URL" "${login_confirm_url}"
set_toml_string "STRIPE_SUCCESS_URL" "${stripe_success_url}"
set_toml_string "STRIPE_CANCEL_URL" "${stripe_cancel_url}"
set_toml_string "database_id" "${d1_database_id}"

echo "Spider release configuration updated."
echo "Run: bash scripts/release_preflight.sh"
