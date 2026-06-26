#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INFO_PLIST="${PROJECT_DIR}/leanring-buddy/Info.plist"
PBXPROJ="${PROJECT_DIR}/leanring-buddy.xcodeproj/project.pbxproj"
SHARED_SCHEME="${PROJECT_DIR}/leanring-buddy.xcodeproj/xcshareddata/xcschemes/leanring-buddy.xcscheme"
ENTITLEMENTS="${PROJECT_DIR}/leanring-buddy/leanring-buddy.entitlements"
WRANGLER="${PROJECT_DIR}/worker/wrangler.toml"
APPCAST="${PROJECT_DIR}/appcast.xml"
CONFIGURE_RELEASE="${PROJECT_DIR}/scripts/configure_release.sh"
GROUNDING_TELEMETRY_AUDIT="${PROJECT_DIR}/scripts/grounding_telemetry_audit.mjs"
WORKER_DEPLOY_PREFLIGHT="${PROJECT_DIR}/scripts/worker_deploy_preflight.sh"
WORKER_REMOTE_PREFLIGHT="${PROJECT_DIR}/scripts/worker_remote_preflight.sh"
WORKER_SRC_DIR="${PROJECT_DIR}/worker/src"
WORKER_TESTS_DIR="${PROJECT_DIR}/worker/tests"
VISION_GUIDE_CONTRACTS_SWIFT="${PROJECT_DIR}/leanring-buddy/OpenAIAPI.swift"
VISION_GUIDE_CLIENT_SWIFT="${PROJECT_DIR}/leanring-buddy/OpenAIVisionGuideClient.swift"
VISION_GUIDE_SANITIZATION_SWIFT="${PROJECT_DIR}/leanring-buddy/SpiderGuideResponseSanitization.swift"
VISION_GUIDE_ACTIONS_SWIFT="${PROJECT_DIR}/leanring-buddy/CompanionManagerVisionGuideActions.swift"
SECURITY_DECISIONS="${PROJECT_DIR}/SPIDER_SECURITY_RELEASE_DECISIONS.md"
SUBSCRIPTION_MIGRATION="${PROJECT_DIR}/worker/migrations/0002_subscription_state.sql"
STRIPE_EVENT_MIGRATION="${PROJECT_DIR}/worker/migrations/0003_stripe_event_processing.sql"
SESSION_DEVICE_MIGRATION="${PROJECT_DIR}/worker/migrations/0004_session_device_binding.sql"
RETENTION_INDEX_MIGRATION="${PROJECT_DIR}/worker/migrations/0005_operational_retention_indexes.sql"

errors=0
warnings=0

error() {
    errors=$((errors + 1))
    echo "ERROR: $*"
}

warn() {
    warnings=$((warnings + 1))
    echo "WARN:  $*"
}

ok() {
    echo "OK:    $*"
}

plist_read() {
    /usr/libexec/PlistBuddy -c "Print :$1" "${INFO_PLIST}" 2>/dev/null || true
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

require_file() {
    if [ -f "$1" ]; then
        ok "Found ${1#"${PROJECT_DIR}/"}"
    else
        error "Missing ${1#"${PROJECT_DIR}/"}"
    fi
}

rg_quiet_status() {
    local pattern="$1"
    shift

    local status
    set +e
    rg -q \
        --glob "!scripts/release_preflight.sh" \
        --glob "!worker/node_modules/**" \
        --glob "!worker/.wrangler/**" \
        --glob "!tmp/**" \
        -- "${pattern}" "$@"
    status=$?
    set -e

    printf "%s" "${status}"
}

fail_if_rg_matches() {
    local pattern="$1"
    local description="$2"
    shift 2

    case "$(rg_quiet_status "${pattern}" "$@")" in
        0)
            error "${description}"
            ;;
        1)
            ok "${description}"
            ;;
        *)
            error "${description} (preflight rg check failed)"
            ;;
    esac
}

require_rg_match() {
    local pattern="$1"
    local description="$2"
    shift 2

    case "$(rg_quiet_status "${pattern}" "$@")" in
        0)
            ok "${description}"
            ;;
        1)
            error "${description}"
            ;;
        *)
            error "${description} (preflight rg check failed)"
            ;;
    esac
}

first_rg_line_number_status() {
    local pattern="$1"
    shift

    local matches
    local status
    set +e
    matches="$(rg -n -- "${pattern}" "$@")"
    status=$?
    set -e

    if [ "${status}" -eq 0 ]; then
        printf "0:%s" "${matches%%:*}"
    else
        printf "%s:" "${status}"
    fi
}

asset_find_status() {
    local pipeline_status
    set +e
    find "${PROJECT_DIR}/leanring-buddy/Assets.xcassets" -iname "*makesomething*" | rg -q "."
    pipeline_status=("${PIPESTATUS[@]}")
    set -e

    if [ "${pipeline_status[0]}" -ne 0 ]; then
        printf "2"
    else
        printf "%s" "${pipeline_status[1]}"
    fi
}

run_worker_check() {
    if [ "${SPIDER_SKIP_WORKER_SMOKE:-0}" = "1" ]; then
        warn "Skipping Worker checks because SPIDER_SKIP_WORKER_SMOKE=1"
        return
    fi

    if (cd "${PROJECT_DIR}/worker" && npm run check); then
        ok "Worker typecheck and smoke tests pass"
    else
        error "Worker typecheck or smoke tests failed"
    fi
}

run_grounding_telemetry_audit_self_test() {
    if node "${GROUNDING_TELEMETRY_AUDIT}" --self-test >/dev/null; then
        ok "Grounding telemetry audit CLI positive and negative self-test passes"
    else
        error "Grounding telemetry audit CLI positive or negative self-test failed"
    fi
}

check_auth_start_validation_order() {
    local read_line
    local device_line
    local rate_line
    local read_result
    local device_result
    local rate_result

    read_result="$(first_rg_line_number_status "const body = await readJSONRequest" "${WORKER_SRC_DIR}/authRoutes.ts")"
    device_result="$(first_rg_line_number_status "await requiredDeviceHashFromRequest\\(request\\);" "${WORKER_SRC_DIR}/authRoutes.ts")"
    rate_result="$(first_rg_line_number_status "await consumeRequestRateLimits\\(request, env, \"auth_start\"" "${WORKER_SRC_DIR}/authRoutes.ts")"

    if [[ "${read_result}" != 0:* ]] || [[ "${device_result}" != 0:* ]] || [[ "${rate_result}" != 0:* ]]; then
        error "Worker auth start validation order is checkable"
        return
    fi

    read_line="${read_result#0:}"
    device_line="${device_result#0:}"
    rate_line="${rate_result#0:}"

    if [ -z "${read_line}" ] || [ -z "${device_line}" ] || [ -z "${rate_line}" ]; then
        error "Worker auth start validation order is checkable"
        return
    fi

    if [ "${read_line}" -lt "${device_line}" ] && [ "${device_line}" -lt "${rate_line}" ]; then
        ok "Worker validates auth login body and device id before rate-limit writes"
    else
        error "Worker validates auth login body and device id before rate-limit writes"
    fi
}

check_vision_token_before_payload() {
    local token_line
    local payload_line
    local token_result
    local payload_result

    token_result="$(first_rg_line_number_status "guard let token = tokenProvider\\(\\)\\.flatMap\\(SpiderWorkerTokenValidator.normalizedDoubleUUIDV4Token\\)" "${VISION_GUIDE_CLIENT_SWIFT}")"
    payload_result="$(first_rg_line_number_status "let payload = SpiderVisionGuideRequest" "${VISION_GUIDE_CLIENT_SWIFT}")"

    if [[ "${token_result}" != 0:* ]] || [[ "${payload_result}" != 0:* ]]; then
        error "macOS Vision client token-before-payload order is checkable"
        return
    fi

    token_line="${token_result#0:}"
    payload_line="${payload_result#0:}"

    if [ "${token_line}" -lt "${payload_line}" ]; then
        ok "macOS Vision client requires a Worker token before encoding screenshots"
    else
        error "macOS Vision client requires a Worker token before encoding screenshots"
    fi
}

check_realtime_token_before_secret_request() {
    local token_line
    local request_line
    local token_result
    local request_result

    token_result="$(first_rg_line_number_status "guard let token = tokenProvider\\(\\)\\.flatMap\\(SpiderWorkerTokenValidator.normalizedDoubleUUIDV4Token\\)" "${PROJECT_DIR}/leanring-buddy/OpenAIRealtimeVoiceClient.swift")"
    request_result="$(first_rg_line_number_status "var request = URLRequest\\(url: clientSecretURL\\)" "${PROJECT_DIR}/leanring-buddy/OpenAIRealtimeVoiceClient.swift")"

    if [[ "${token_result}" != 0:* ]] || [[ "${request_result}" != 0:* ]]; then
        error "macOS Realtime client token-before-request order is checkable"
        return
    fi

    token_line="${token_result#0:}"
    request_line="${request_result#0:}"

    if [ "${token_line}" -lt "${request_line}" ]; then
        ok "macOS Realtime client requires a Worker token before requesting a client secret"
    else
        error "macOS Realtime client requires a Worker token before requesting a client secret"
    fi
}

check_release_preflight_order() {
    local local_result
    local remote_result
    local archive_result
    local local_line
    local remote_line
    local archive_line

    local_result="$(first_rg_line_number_status "bash \"\\$\\{PROJECT_DIR\\}/scripts/release_preflight\\.sh\"" "${PROJECT_DIR}/scripts/release.sh")"
    remote_result="$(first_rg_line_number_status "bash \"\\$\\{PROJECT_DIR\\}/scripts/worker_remote_preflight\\.sh\"" "${PROJECT_DIR}/scripts/release.sh")"
    archive_result="$(first_rg_line_number_status "xcodebuild archive" "${PROJECT_DIR}/scripts/release.sh")"

    if [[ "${local_result}" != 0:* ]] || [[ "${remote_result}" != 0:* ]] || [[ "${archive_result}" != 0:* ]]; then
        error "Release script preflight/archive order is checkable"
        return
    fi

    local_line="${local_result#0:}"
    remote_line="${remote_result#0:}"
    archive_line="${archive_result#0:}"

    if [ -z "${local_line}" ] || [ -z "${remote_line}" ] || [ -z "${archive_line}" ]; then
        error "Release script preflight/archive order is checkable"
        return
    fi

    if [ "${local_line}" -lt "${remote_line}" ] && [ "${remote_line}" -lt "${archive_line}" ]; then
        ok "Release script runs local and remote preflights before archive"
    else
        error "Release script must run local preflight, then remote Worker preflight, before archive/export"
    fi
}

check_https_url() {
    local value="$1"
    local description="$2"

    if [ -z "${value}" ]; then
        error "${description} is empty"
    elif is_placeholder_url "${value}"; then
        error "${description} still points to a placeholder or local host"
    elif [[ "${value}" != https://* ]]; then
        error "${description} must use https://"
    else
        ok "${description} is production-shaped"
    fi
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

check_magic_link_confirm_url() {
    local value="$1"

    if [ -z "${value}" ]; then
        error "APP_LOGIN_CONFIRM_URL is empty"
    elif is_placeholder_url "${value}"; then
        error "APP_LOGIN_CONFIRM_URL still points to a placeholder or local host"
    elif [[ "${value}" != https://* ]]; then
        error "APP_LOGIN_CONFIRM_URL must be the HTTPS Worker /auth/login/confirm URL for production email"
    elif [[ "${value}" != */auth/login/confirm* ]]; then
        error "APP_LOGIN_CONFIRM_URL HTTPS mode must point to /auth/login/confirm"
    else
        ok "Worker magic links use HTTPS browser bridge"
    fi
}

echo "Spider release preflight"
echo

require_file "${INFO_PLIST}"
require_file "${PBXPROJ}"
require_file "${SHARED_SCHEME}"
require_file "${ENTITLEMENTS}"
require_file "${WRANGLER}"
require_file "${APPCAST}"
require_file "${CONFIGURE_RELEASE}"
require_file "${GROUNDING_TELEMETRY_AUDIT}"
require_file "${WORKER_DEPLOY_PREFLIGHT}"
require_file "${WORKER_REMOTE_PREFLIGHT}"
require_file "${VISION_GUIDE_CLIENT_SWIFT}"
require_file "${VISION_GUIDE_SANITIZATION_SWIFT}"
require_file "${VISION_GUIDE_ACTIONS_SWIFT}"
require_file "${SECURITY_DECISIONS}"
require_file "${SUBSCRIPTION_MIGRATION}"
require_file "${STRIPE_EVENT_MIGRATION}"
require_file "${SESSION_DEVICE_MIGRATION}"
require_file "${RETENTION_INDEX_MIGRATION}"
require_file "${WORKER_TESTS_DIR}/smoke-worker.mjs"
require_file "${PROJECT_DIR}/worker/worker-configuration.d.ts"

echo
echo "Plists"
plutil -lint "${INFO_PLIST}" >/dev/null && ok "Info.plist parses"
plutil -lint "${PBXPROJ}" >/dev/null && ok "Xcode project plist parses"
xmllint --noout "${SHARED_SCHEME}" >/dev/null && ok "Shared Xcode scheme parses"
plutil -lint "${ENTITLEMENTS}" >/dev/null && ok "Entitlements plist parses"
xmllint --noout "${APPCAST}" >/dev/null && ok "appcast.xml parses"
bash -n "${CONFIGURE_RELEASE}" && ok "configure_release.sh parses"
bash -n "${WORKER_DEPLOY_PREFLIGHT}" && ok "worker_deploy_preflight.sh parses"
bash -n "${WORKER_REMOTE_PREFLIGHT}" && ok "worker_remote_preflight.sh parses"

echo
echo "macOS app configuration"
check_https_url "$(plist_read SUFeedURL)" "Sparkle SUFeedURL"
check_https_url "$(plist_read SpiderWorkerBaseURL)" "SpiderWorkerBaseURL"

voice_provider="$(plist_read VoiceTranscriptionProvider)"
if [ "${voice_provider}" = "realtime" ]; then
    ok "VoiceTranscriptionProvider is realtime"
else
    error "VoiceTranscriptionProvider must be realtime for Spider release"
fi

development_token="$(plist_read SpiderDevelopmentSessionToken)"
if [ -n "${development_token}" ]; then
    error "SpiderDevelopmentSessionToken must be absent or empty in release builds"
else
    ok "No development session token in Info.plist"
fi

require_rg_match "PRODUCT_NAME = Spider;" "Product name is Spider" "${PBXPROJ}"
require_rg_match "INFOPLIST_KEY_CFBundleDisplayName = Spider;" "Bundle display name is Spider" "${PBXPROJ}"
require_rg_match "ENABLE_HARDENED_RUNTIME = YES;" "Hardened Runtime is enabled" "${PBXPROJ}"
require_rg_match "<string>spider</string>" "spider:// URL scheme is registered" "${INFO_PLIST}"
fail_if_rg_matches "com\\.yourcompany\\.leanring-buddy" "Bundle identifier is not the template com.yourcompany value" "${PBXPROJ}"

case "$(rg_quiet_status "ENABLE_APP_SANDBOX = NO;" "${PBXPROJ}")" in
    0)
        require_rg_match "Decision: App Sandbox disabled for paid beta" "App Sandbox disabled release exception is explicit" "${SECURITY_DECISIONS}"
        require_rg_match "Required compensating controls" "App Sandbox exception names compensating controls" "${SECURITY_DECISIONS}"
        require_rg_match "Required beta QA before distribution" "App Sandbox exception requires beta QA" "${SECURITY_DECISIONS}"
        require_rg_match "Required review before stable release" "App Sandbox exception requires stable-release review" "${SECURITY_DECISIONS}"
        require_rg_match "ScreenCaptureKit" "App Sandbox exception covers ScreenCaptureKit risk" "${SECURITY_DECISIONS}"
        require_rg_match "CGEvent tap" "App Sandbox exception covers global hotkey risk" "${SECURITY_DECISIONS}"
        require_rg_match "Accessibility" "App Sandbox exception covers Accessibility risk" "${SECURITY_DECISIONS}"
        ;;
    1)
        ok "App Sandbox is not disabled in project settings"
        ;;
    *)
        error "App Sandbox project setting is checkable"
        ;;
esac

echo
echo "Worker production configuration"
fail_if_rg_matches "spider\\.example\\.com|\\.example|yourdomain\\.com|\\.test|\\.invalid|localhost|replace-with-cloudflare-d1-database-id" "Worker has no placeholder production URL or D1 database id" "${WRANGLER}"
check_magic_link_confirm_url "$(toml_string APP_LOGIN_CONFIRM_URL)"
require_rg_match "APP_LOGIN_DEEP_LINK_URL = \"spider://auth/confirm\"" "Worker browser bridge targets spider://auth/confirm" "${WRANGLER}"
require_rg_match "OPENAI_REALTIME_MODEL = \"gpt-realtime-2\"" "Worker uses gpt-realtime-2 for Realtime" "${WRANGLER}"
require_rg_match "compatibility_date = \"2026-06-18\"" "Worker compatibility date is current for this release train" "${WRANGLER}"
require_rg_match "compatibility_flags = \\[\"nodejs_compat\"\\]" "Worker explicitly enables nodejs_compat" "${WRANGLER}"
require_rg_match "\\[observability\\]" "Worker observability is configured" "${WRANGLER}"
require_rg_match "head_sampling_rate" "Worker log sampling is explicit" "${WRANGLER}"
require_rg_match "\\[triggers\\]" "Worker scheduled cleanup trigger is configured" "${WRANGLER}"
require_rg_match "pruneOperationalRows" "Worker prunes expired operational rows" "${WORKER_SRC_DIR}"
require_rg_match "\"smoke\": \"node tests/smoke-worker.mjs\"" "Worker smoke test script is registered" "${PROJECT_DIR}/worker/package.json"
require_rg_match "\"typegen\": \"WRANGLER_LOG_PATH=.* wrangler types\"" "Worker typegen script is registered with sandbox-safe Wrangler logs" "${PROJECT_DIR}/worker/package.json"
require_rg_match "\"typegen:check\": \"WRANGLER_LOG_PATH=.* wrangler types --check\"" "Worker generated-type check script is registered" "${PROJECT_DIR}/worker/package.json"
require_rg_match "\"typecheck\": \"tsc --noEmit\"" "Worker typecheck script is registered" "${PROJECT_DIR}/worker/package.json"
require_rg_match "\"check\": \"npm run typegen:check && npm run typecheck && npm run smoke\"" "Worker check script rejects stale generated bindings" "${PROJECT_DIR}/worker/package.json"
require_rg_match "interface Env extends __BaseEnv_Env" "Worker uses Wrangler-generated Env bindings" "${PROJECT_DIR}/worker/worker-configuration.d.ts"
require_rg_match "DAILY_IP_AUTH_CONFIRM_LIMIT" "Worker config defines IP rate limits for magic-link confirm" "${WRANGLER}" "${PROJECT_DIR}/worker/worker-configuration.d.ts"
require_rg_match "DAILY_DEVICE_AUTH_CONFIRM_LIMIT" "Worker config defines device rate limits for magic-link confirm" "${WRANGLER}" "${PROJECT_DIR}/worker/worker-configuration.d.ts"
require_rg_match "magicLinkConfirmURL" "Worker validates magic-link email URL at runtime" "${WORKER_SRC_DIR}"
require_rg_match "magicLinkTokenFromURL" "Worker validates magic-link token format before D1" "${WORKER_SRC_DIR}"
require_rg_match "MAGIC_LINK_TOKEN_PATTERN" "Worker accepts only production-shaped magic-link tokens" "${WORKER_SRC_DIR}"
require_rg_match "sessionTokenFromRequest" "Worker validates bearer session token format before D1" "${WORKER_SRC_DIR}"
require_rg_match "SESSION_TOKEN_PATTERN" "Worker accepts only production-shaped bearer session tokens" "${WORKER_SRC_DIR}"
require_rg_match "const deviceHash = await requiredDeviceHashFromRequest\\(request\\)" "Worker requires device-bound sessions before D1 lookup" "${WORKER_SRC_DIR}"
require_rg_match "requireProductionHTTPSURL" "Worker validates production HTTPS redirect URLs at runtime" "${WORKER_SRC_DIR}"
require_rg_match "requireOpenAISecret" "Worker validates OpenAI server configuration before AI quota/audit" "${WORKER_SRC_DIR}"
require_rg_match "OPENAI_MODEL_NAME_PATTERN" "Worker restricts configured OpenAI model names to safe characters" "${WORKER_SRC_DIR}"
require_rg_match "configuredOpenAIModel" "Worker validates configured OpenAI model names before AI quota/audit" "${WORKER_SRC_DIR}"
require_rg_match "OPENAI_CLIENT_SECRET_VALUE_PATTERN" "Worker restricts Realtime client-secret values before returning them" "${WORKER_SRC_DIR}"
require_rg_match "device_hash" "D1 migration binds sessions to a hashed device id" "${SESSION_DEVICE_MIGRATION}"
require_rg_match "SET revoked_at = unixepoch\\(\\)" "D1 migration revokes legacy sessions without device hashes" "${SESSION_DEVICE_MIGRATION}"
require_rg_match "requiredDeviceHashFromRequest" "Worker requires a device id before creating app sessions" "${WORKER_SRC_DIR}"
require_rg_match "MAX_DEVICE_IDENTIFIER_CHARS" "Worker caps device id length before hashing" "${WORKER_SRC_DIR}"
require_rg_match "DEVICE_IDENTIFIER_PATTERN" "Worker rejects unsafe device id characters before hashing" "${WORKER_SRC_DIR}"
require_rg_match "deviceIdentifierFromRequest" "Worker centralizes device id validation" "${WORKER_SRC_DIR}"
require_rg_match "MAX_CLIENT_IP_ADDRESS_CHARS" "Worker caps Cloudflare IP header length before hashing" "${WORKER_SRC_DIR}"
require_rg_match "clientIPAddressFromRequest" "Worker centralizes trusted client IP extraction" "${WORKER_SRC_DIR}"
fail_if_rg_matches "x-forwarded-for" "Worker does not trust spoofable x-forwarded-for for rate limits" "${WORKER_SRC_DIR}"
fail_if_rg_matches "sessions\\.device_hash IS NULL" "Worker does not accept legacy sessions without device hashes" "${WORKER_SRC_DIR}"
require_rg_match "auth login start requires a device id before touching D1" "Worker smoke blocks auth-start without device id before writes" "${WORKER_TESTS_DIR}"
require_rg_match "auth login start rejects invalid device ids before touching D1" "Worker smoke rejects invalid auth-start device ids before writes" "${WORKER_TESTS_DIR}"
require_rg_match "auth login start stores only a hashed device id in rate counters" "Worker smoke stores auth-start device ids only as hashes" "${WORKER_TESTS_DIR}"
require_rg_match "consumeMagicLinkByHash" "Worker consumes undelivered magic links after email delivery failures" "${WORKER_SRC_DIR}"
require_rg_match "revokePreviousActiveMagicLinks" "Worker revokes previous active magic links after successful delivery" "${WORKER_SRC_DIR}"
require_rg_match "auth login start revokes previous active magic links after creating a deliverable link" "Worker smoke proves latest delivered magic link replaces prior links" "${WORKER_TESTS_DIR}"
require_rg_match "auth login start preserves old links and consumes the new link when email delivery fails" "Worker smoke preserves old magic links on email delivery failure" "${WORKER_TESTS_DIR}"
require_rg_match "auth login start ignores spoofable x-forwarded-for for IP rate limits" "Worker smoke ignores spoofable x-forwarded-for rate-limit actors" "${WORKER_TESTS_DIR}"
require_rg_match "auth login start rejects oversized Cloudflare IP headers before touching D1" "Worker smoke rejects oversized Cloudflare IP headers before writes" "${WORKER_TESTS_DIR}"
require_rg_match "auth login confirm requires a device id before touching D1" "Worker smoke blocks session creation without device id before writes" "${WORKER_TESTS_DIR}"
require_rg_match "auth login confirm rejects missing tokens before touching D1" "Worker smoke rejects missing magic-link tokens before writes" "${WORKER_TESTS_DIR}"
require_rg_match "auth login confirm rejects malformed tokens before touching D1" "Worker smoke rejects malformed magic-link tokens before writes" "${WORKER_TESTS_DIR}"
require_rg_match "magic-link browser bridge rejects malformed tokens before touching D1" "Worker smoke rejects malformed browser-bridge tokens before writes" "${WORKER_TESTS_DIR}"
require_rg_match "auth login confirm rejects extra query parameters before touching D1" "Worker smoke rejects extra app magic-link query params before writes" "${WORKER_TESTS_DIR}"
require_rg_match "magic-link browser bridge rejects extra query parameters before touching D1" "Worker smoke rejects extra browser magic-link query params before writes" "${WORKER_TESTS_DIR}"
require_rg_match "auth login confirm rejects invalid device ids before touching D1" "Worker smoke rejects invalid confirm device ids before writes" "${WORKER_TESTS_DIR}"
require_rg_match "auth login confirm blocks exhausted device rate limit before magic-link lookup" "Worker smoke rate-limits app magic-link confirm before lookup" "${WORKER_TESTS_DIR}"
require_rg_match "magic-link browser bridge blocks exhausted IP rate limit before magic-link lookup" "Worker smoke rate-limits browser magic-link bridge before lookup" "${WORKER_TESTS_DIR}"
require_rg_match "auth login confirm stores only a device hash with the session" "Worker smoke stores device hashes without raw device ids" "${WORKER_TESTS_DIR}"
fail_if_rg_matches "test-magic-token" "Worker tests use production-shaped magic-link tokens" "${WORKER_TESTS_DIR}"
require_rg_match "auth status rejects a device-bound session from a different device" "Worker smoke rejects session reuse from another device" "${WORKER_TESTS_DIR}"
require_rg_match "auth status requires a device id before touching D1" "Worker smoke blocks auth status without device id before D1" "${WORKER_TESTS_DIR}"
require_rg_match "auth status rejects legacy sessions without a device hash" "Worker smoke rejects legacy sessions without device hashes" "${WORKER_TESTS_DIR}"
require_rg_match "auth status accepts a device-bound session from the same device" "Worker smoke accepts matching device-bound sessions" "${WORKER_TESTS_DIR}"
require_rg_match "crypto.subtle.timingSafeEqual" "Worker compares Stripe signatures with Web Crypto timing-safe equality" "${WORKER_SRC_DIR}"
require_rg_match "Math\\.abs\\(now - timestampNumber\\) > 300" "Worker rejects stale Stripe webhook signatures" "${WORKER_SRC_DIR}"
require_rg_match "Stripe webhooks with expired signatures fail before touching D1" "Worker smoke rejects stale Stripe signatures before writes" "${WORKER_TESTS_DIR}"
fail_if_rg_matches "function requireStripe\\(" "Worker avoids monolithic Stripe configuration checks" "${WORKER_SRC_DIR}"
require_rg_match "requireStripePriceID" "Worker scopes Stripe price config to checkout" "${WORKER_SRC_DIR}"
require_rg_match "requireStripeAPISecret" "Worker scopes Stripe API key config to Stripe API calls" "${WORKER_SRC_DIR}"
require_rg_match "requireStripeWebhookSecret" "Worker scopes Stripe webhook secret config to signature verification" "${WORKER_SRC_DIR}"
require_rg_match "Stripe subscription webhooks do not require checkout price configuration" "Worker smoke proves webhooks do not depend on checkout price config" "${WORKER_TESTS_DIR}"
require_rg_match "billing checkout fails missing Stripe API key before audit or fetch" "Worker smoke proves checkout validates Stripe API key before audit/fetch" "${WORKER_TESTS_DIR}"
require_rg_match "billing portal fails missing Stripe API key before audit or fetch" "Worker smoke proves portal validates Stripe API key before audit/fetch" "${WORKER_TESTS_DIR}"
require_rg_match "subscription_data\\[metadata\\]\\[spider_user_id\\]" "Stripe Checkout sessions tag subscriptions with Spider user metadata" "${WORKER_SRC_DIR}"
require_rg_match "stripeHostedSessionURL.*checkout\\.stripe\\.com" "Worker pins Checkout URLs to Stripe-hosted Checkout" "${WORKER_SRC_DIR}"
require_rg_match "stripeHostedSessionURL.*billing\\.stripe\\.com" "Worker pins portal URLs to Stripe-hosted billing portal" "${WORKER_SRC_DIR}"
require_rg_match "url\\.hostname !== allowedHostname" "Worker rejects Stripe session URL host mismatches" "${WORKER_SRC_DIR}"
require_rg_match "billing checkout rejects unsafe Stripe checkout URLs" "Worker smoke rejects unsafe Stripe checkout URLs" "${WORKER_TESTS_DIR}"
require_rg_match "billing portal returns only Stripe-hosted portal URLs" "Worker smoke accepts Stripe-hosted portal URLs" "${WORKER_TESTS_DIR}"
require_rg_match "billing portal rejects unsafe Stripe portal URLs" "Worker smoke rejects unsafe Stripe portal URLs" "${WORKER_TESTS_DIR}"
require_rg_match "billing checkout blocks users with active entitlement before calling Stripe" "Worker smoke blocks duplicate checkout for active users" "${WORKER_TESTS_DIR}"
require_rg_match "billing checkout blocks canceled subscriptions while paid period is still active" "Worker smoke blocks duplicate checkout during paid cancellation period" "${WORKER_TESTS_DIR}"
require_rg_match "Stripe checkout webhooks link customer and subscription without granting entitlement directly" "Worker smoke proves checkout does not grant entitlement directly" "${WORKER_TESTS_DIR}"
require_rg_match "Stripe checkout webhooks without a subscription do not update entitlement" "Worker smoke covers malformed checkout entitlement blocking" "${WORKER_TESTS_DIR}"
require_rg_match "Stripe active subscription webhooks grant entitlement from subscription status" "Worker smoke covers subscription-status entitlement grants" "${WORKER_TESTS_DIR}"
require_rg_match "Stripe incomplete subscription webhooks do not grant active entitlement" "Worker smoke covers incomplete subscription blocking" "${WORKER_TESTS_DIR}"
require_rg_match "Stripe paid invoice webhooks reconcile active subscription state" "Worker smoke covers paid invoice subscription reconciliation" "${WORKER_TESTS_DIR}"
require_rg_match "Stripe failed invoice webhooks reconcile non-active subscription state" "Worker smoke covers failed invoice entitlement reconciliation" "${WORKER_TESTS_DIR}"
require_rg_match "Stripe invoice webhooks without subscription do not call Stripe or update entitlement" "Worker smoke covers invoice events without subscription ids" "${WORKER_TESTS_DIR}"
require_rg_match "validateVisionGuideRequest" "Worker validates vision payload shape before OpenAI calls" "${WORKER_SRC_DIR}"
require_rg_match "MAX_SCREENSHOT_COUNT" "Worker caps screenshots per vision request" "${WORKER_SRC_DIR}"
require_rg_match "vision guide rejects invalid screenshots before calling OpenAI" "Worker smoke covers invalid screenshot rejection before OpenAI" "${WORKER_TESTS_DIR}"
require_rg_match "vision guide blocks unpaid users before quota, audit, or OpenAI" "Worker smoke covers unpaid Vision blocking before cost/audit" "${WORKER_TESTS_DIR}"
require_rg_match "auth status derives access from Stripe subscription over stale active entitlement" "Worker smoke proves Stripe subscription state beats stale stored entitlement" "${WORKER_TESTS_DIR}"
require_rg_match "auth status ends canceled access after the paid period expires" "Worker smoke proves canceled subscriptions expire after paid period" "${WORKER_TESTS_DIR}"
require_rg_match "auth status rejects malformed bearer tokens before touching D1" "Worker smoke rejects malformed bearer tokens before writes" "${WORKER_TESTS_DIR}"
fail_if_rg_matches "paid-session-token|unpaid-session-token" "Worker tests use production-shaped bearer session tokens" "${WORKER_TESTS_DIR}"
require_rg_match "content-security-policy" "Worker browser bridge returns a Content Security Policy" "${WORKER_SRC_DIR}"
require_rg_match "script-src 'none'" "Worker browser bridge blocks script execution" "${WORKER_SRC_DIR}" "${WORKER_TESTS_DIR}"
fail_if_rg_matches "<script|window\\.location\\.replace" "Worker browser bridge does not include inline JavaScript" "${WORKER_SRC_DIR}"
require_rg_match "frame-ancestors 'none'" "Worker browser bridge blocks framing" "${WORKER_SRC_DIR}" "${WORKER_TESTS_DIR}"
require_rg_match "vision guide blocks stale active entitlement when Stripe subscription is past due" "Worker smoke blocks stale active entitlement before AI cost" "${WORKER_TESTS_DIR}"
require_rg_match "Realtime client secret blocks unpaid users before quota, audit, or OpenAI" "Worker smoke covers unpaid Realtime blocking before cost/audit" "${WORKER_TESTS_DIR}"
require_rg_match "vision guide fails missing OpenAI config before quota, audit, or OpenAI" "Worker smoke covers missing OpenAI config before Vision cost/audit" "${WORKER_TESTS_DIR}"
require_rg_match "Realtime client secret fails missing OpenAI config before quota, audit, or OpenAI" "Worker smoke covers missing OpenAI config before Realtime cost/audit" "${WORKER_TESTS_DIR}"
require_rg_match "vision guide fails unsafe OpenAI model config before quota, audit, or OpenAI" "Worker smoke covers unsafe Vision model config before cost/audit" "${WORKER_TESTS_DIR}"
require_rg_match "Realtime client secret fails unsafe OpenAI model config before quota, audit, or OpenAI" "Worker smoke covers unsafe Realtime model config before cost/audit" "${WORKER_TESTS_DIR}"
require_rg_match "OpenAI-Safety-Identifier.*user\\.emailHash" "Worker passes stable non-content safety identifiers to OpenAI" "${WORKER_SRC_DIR}"
require_rg_match "safety_identifier: safetyIdentifier" "Worker includes safety identifiers in Responses API request bodies" "${WORKER_SRC_DIR}"
require_rg_match "vision guide sends stable OpenAI safety identifiers without user content" "Worker smoke proves Vision safety identifiers do not use user content" "${WORKER_TESTS_DIR}"
require_rg_match "Realtime client secret sends stable OpenAI safety identifier without user content" "Worker smoke proves Realtime safety identifiers do not use user content" "${WORKER_TESTS_DIR}"
fail_if_rg_matches "body\\.visionModel" "Worker does not trust client-provided Vision model overrides" "${WORKER_SRC_DIR}"
require_rg_match "vision guide ignores client-provided model overrides" "Worker smoke proves Vision model is server-controlled" "${WORKER_TESTS_DIR}"
fail_if_rg_matches "SpiderVisionModel|SpiderConfiguration\\.visionModel|selectedOpenAIVisionModel|setSelectedModel|modelPickerRow|modelOptionButton" "macOS app does not expose client-side AI model switching" "${PROJECT_DIR}/leanring-buddy"
require_rg_match "realtimeClientSecretPayload" "Worker wraps Realtime client secrets with server-controlled model metadata" "${WORKER_SRC_DIR}"
fail_if_rg_matches "\\.\\.\\.payload" "Worker does not proxy raw OpenAI Realtime client-secret payloads" "${WORKER_SRC_DIR}"
require_rg_match "Realtime client secret returns only the minimal client envelope" "Worker smoke proves Realtime client-secret response is minimal" "${WORKER_TESTS_DIR}"
require_rg_match "Realtime client secret ignores client-provided model overrides" "Worker smoke proves Realtime model is server-controlled" "${WORKER_TESTS_DIR}"
require_rg_match "OpenAI returned an invalid realtime response" "Worker maps malformed Realtime envelopes to sanitized upstream errors" "${WORKER_SRC_DIR}"
require_rg_match "Realtime client secret maps invalid OpenAI response envelopes to sanitized 502" "Worker smoke covers malformed Realtime response envelopes" "${WORKER_TESTS_DIR}"
require_rg_match "Realtime client secret maps missing OpenAI client secrets to sanitized 502" "Worker smoke covers missing Realtime client secret payloads" "${WORKER_TESTS_DIR}"
require_rg_match "Realtime client secret maps unsafe OpenAI client secrets to sanitized 502" "Worker smoke covers unsafe Realtime client secret payloads" "${WORKER_TESTS_DIR}"
fail_if_rg_matches "SpiderRealtimeModel|SpiderConfiguration\\.realtimeModel|realtimeModel" "macOS app does not expose client-side Realtime model switching" "${PROJECT_DIR}/leanring-buddy"
require_rg_match "OpenAI returned an invalid vision response" "Worker maps malformed OpenAI envelopes to sanitized upstream errors" "${WORKER_SRC_DIR}"
require_rg_match "guideResponsePayload" "Worker validates structured Vision guide responses before returning them" "${WORKER_SRC_DIR}"
require_rg_match "MAX_GUIDE_DISPLAY_TEXT_CHARS" "Worker caps Vision guide display text before app delivery" "${WORKER_SRC_DIR}"
require_rg_match "MAX_ARTIFACT_MARKDOWN_CHARS" "Worker caps Vision guide artifacts before app delivery" "${WORKER_SRC_DIR}"
require_rg_match "vision guide maps invalid OpenAI response envelopes to sanitized 502" "Worker smoke covers malformed OpenAI response envelopes" "${WORKER_TESTS_DIR}"
require_rg_match "vision guide maps invalid OpenAI guide payloads to sanitized 502" "Worker smoke covers malformed OpenAI guide payloads" "${WORKER_TESTS_DIR}"
require_rg_match "vision guide maps oversized OpenAI guide payloads to sanitized 502" "Worker smoke covers oversized OpenAI guide payloads" "${WORKER_TESTS_DIR}"
require_rg_match "vision guide maps invalid OpenAI guide artifacts to sanitized 502" "Worker smoke covers invalid OpenAI guide artifacts" "${WORKER_TESTS_DIR}"
require_rg_match "vision guide maps invalid OpenAI Ad Mission updates to sanitized 502" "Worker smoke covers invalid OpenAI Ad Mission updates" "${WORKER_TESTS_DIR}"
require_rg_match "vision guide drops invalid OpenAI point coordinates without losing guidance" "Worker smoke covers invalid point fallback" "${WORKER_TESTS_DIR}"
require_rg_match "vision guide blocks exhausted user quota before audit or OpenAI" "Worker smoke covers quota exhaustion before OpenAI" "${WORKER_TESTS_DIR}"
require_rg_match "RETURNING count" "Worker uses atomic quota/rate counter increments" "${WORKER_SRC_DIR}"
require_rg_match "WHERE count < \\?" "Worker quota/rate counters stop at configured limits atomically" "${WORKER_SRC_DIR}"
fail_if_rg_matches "SELECT count FROM (usage_counters|rate_counters)" "Worker does not use race-prone read-before-increment quota checks" "${WORKER_SRC_DIR}"
require_rg_match "subscription_current_period_end" "D1 migration tracks Stripe subscription period end" "${SUBSCRIPTION_MIGRATION}"
require_rg_match "processing_started_at" "D1 migration tracks in-flight Stripe webhook processing" "${STRIPE_EVENT_MIGRATION}"
require_rg_match "processed_at" "D1 migration tracks processed Stripe webhook events" "${STRIPE_EVENT_MIGRATION}"
require_rg_match "idx_sessions_revoked_at" "D1 migration indexes revoked sessions for retention cleanup" "${RETENTION_INDEX_MIGRATION}"
require_rg_match "idx_usage_counters_day" "D1 migration indexes usage-counter retention cleanup" "${RETENTION_INDEX_MIGRATION}"
require_rg_match "idx_rate_counters_day" "D1 migration indexes rate-counter retention cleanup" "${RETENTION_INDEX_MIGRATION}"
require_rg_match "idx_audit_events_created_at" "D1 migration indexes audit retention cleanup" "${RETENTION_INDEX_MIGRATION}"
require_rg_match "idx_stripe_events_processed_at" "D1 migration indexes processed Stripe-event retention cleanup" "${RETENTION_INDEX_MIGRATION}"
require_rg_match "EMAIL_HASH_SECRET" "Worker requires a server secret for email hashes" "${WORKER_SRC_DIR}"
require_rg_match "MAX_EMAIL_CHARS" "Worker caps login email length before email delivery or D1" "${WORKER_SRC_DIR}"
require_rg_match "EMAIL_PATTERN" "Worker validates login email shape before email delivery or D1" "${WORKER_SRC_DIR}"
require_rg_match "isASCIIString\\(normalized\\)" "Worker rejects non-ASCII login email addresses before email delivery or D1" "${WORKER_SRC_DIR}"
require_rg_match "auth login start rejects invalid email shapes before touching D1" "Worker smoke rejects invalid login email shapes before writes" "${WORKER_TESTS_DIR}"
fail_if_rg_matches "sha256Hex\\(email\\)" "Worker does not store plain SHA-256 email hashes" "${WORKER_SRC_DIR}"
fail_if_rg_matches "access-control-allow-origin.*\\*" "Worker does not ship wildcard CORS headers" "${WORKER_SRC_DIR}"
require_rg_match "allowedWebOrigins" "Worker normalizes configured CORS origins at runtime" "${WORKER_SRC_DIR}"
require_rg_match "normalizedAllowedWebOrigin" "Worker rejects malformed configured CORS origins at runtime" "${WORKER_SRC_DIR}"
require_rg_match "CORS rejects wildcard and insecure configured origins at runtime" "Worker smoke rejects unsafe CORS allowlist entries" "${WORKER_TESTS_DIR}"
require_rg_match "CORS normalizes exact HTTPS origins before matching" "Worker smoke normalizes exact HTTPS CORS origins" "${WORKER_TESTS_DIR}"
check_auth_start_validation_order
case "$(rg_quiet_status 'ALLOWED_WEB_ORIGINS[[:space:]]*=[[:space:]]*"\*"' "${WRANGLER}")" in
    0)
        error "ALLOWED_WEB_ORIGINS must be an explicit origin allowlist, not *"
        ;;
    1)
        ok "Worker CORS origin allowlist is explicit or disabled"
        ;;
    *)
        error "Worker CORS origin allowlist is checkable"
        ;;
esac

echo
echo "Worker behavior checks"
run_worker_check
run_grounding_telemetry_audit_self_test

echo
echo "Legacy provider and secret hygiene"
fail_if_rg_matches "api\\.anthropic|streaming\\.assemblyai|api\\.elevenlabs|posthog|formspark|ANTHROPIC_API_KEY|ASSEMBLYAI_API_KEY|ELEVENLABS_API_KEY|POSTHOG|FORMSPARK|OpenAIAPIKey|https://api\\.openai\\.com/v1/audio|clicky-proxy|your-worker-name|makesomething-mac-app|julianjear|makesomething\\.dmg|<title>makesomething</title>" "No production references to legacy providers, Clicky release endpoints, or old appcast items" "${PROJECT_DIR}"
if [ -f "${PROJECT_DIR}/leanring-buddy/ElevenLabsTTSClient.swift" ]; then
    error "OpenAI Realtime voice client is not kept in a legacy ElevenLabs file"
else
    ok "OpenAI Realtime voice client is not kept in a legacy ElevenLabs file"
fi
if [ -f "${PROJECT_DIR}/leanring-buddy/ClaudeAPI.swift" ]; then
    error "Spider does not keep a legacy Anthropic Claude client file"
else
    ok "Spider does not keep a legacy Anthropic Claude client file"
fi
if [ -f "${PROJECT_DIR}/leanring-buddy/AssemblyAIStreamingTranscriptionProvider.swift" ]; then
    error "Spider does not keep a disabled AssemblyAI transcription provider file"
else
    ok "Spider does not keep a disabled AssemblyAI transcription provider file"
fi
if [ -f "${PROJECT_DIR}/leanring-buddy/OpenAIAudioTranscriptionProvider.swift" ]; then
    error "Spider does not keep a disabled direct OpenAI audio upload provider file"
else
    ok "Spider does not keep a disabled direct OpenAI audio upload provider file"
fi
if [ -f "${PROJECT_DIR}/leanring-buddy/ElementLocationDetector.swift" ]; then
    error "Spider does not keep a disabled client-side element location detector"
else
    ok "Spider does not keep a disabled client-side element location detector"
fi
if [ -f "${PROJECT_DIR}/leanring-buddy/CompanionResponseOverlay.swift" ]; then
    error "Spider does not keep a second unused response overlay surface"
else
    ok "Spider does not keep a second unused response overlay surface"
fi
case "$(asset_find_status)" in
    0)
        error "Spider asset catalog does not keep makesomething-era image assets"
        ;;
    1)
        ok "Spider asset catalog does not keep makesomething-era image assets"
        ;;
    *)
        error "Spider asset catalog scan is checkable"
        ;;
esac
if [ -f "${PROJECT_DIR}/clicky-demo.gif" ]; then
    error "Spider repo does not keep the legacy Clicky demo GIF"
else
    ok "Spider repo does not keep the legacy Clicky demo GIF"
fi
fail_if_rg_matches "sk-proj-|sk-live-|sk-[A-Za-z0-9]{20,}|whsec_[A-Za-z0-9]|rk_live_[A-Za-z0-9]|pk_live_[A-Za-z0-9]" "No obvious API keys or webhook secrets are committed" "${PROJECT_DIR}"
fail_if_rg_matches "SpiderAnalytics\\.track(UserMessageSent|AIResponseReceived|ElementPointed|ResponseError|TTSError)\\([^)]*(transcript:|response:|elementLabel:|error:)" "Analytics calls do not pass user content or error strings" "${PROJECT_DIR}/leanring-buddy"
fail_if_rg_matches "legacy name" "SpiderAnalytics does not describe itself as a legacy shim" "${PROJECT_DIR}/leanring-buddy/SpiderAnalytics.swift"
require_rg_match "print\\(\"Spider metric:" "SpiderAnalytics uses plain DEBUG output" "${PROJECT_DIR}/leanring-buddy/SpiderAnalytics.swift"
set +e
rg -q \
    --glob "!**/SpiderDiagnostics.swift" \
    --glob "!**/SpiderAnalytics.swift" \
    --glob "!worker/node_modules/**" \
    --glob "!worker/.wrangler/**" \
    -- "\\bprint\\(" "${PROJECT_DIR}/leanring-buddy"
print_check_status=$?
set -e
case "${print_check_status}" in
    0)
        error "macOS app routes diagnostic logs through SpiderDiagnostics or SpiderAnalytics only"
        ;;
    1)
        ok "macOS app routes diagnostic logs through SpiderDiagnostics or SpiderAnalytics only"
        ;;
    *)
        error "macOS diagnostic log routing is checkable"
        ;;
esac
fail_if_rg_matches "error\\.localizedDescription|debugDescription|NSLog|os_log|Logger\\(" "macOS app does not log raw Error descriptions" "${PROJECT_DIR}/leanring-buddy"
fail_if_rg_matches "as!" "macOS Swift sources avoid force casts" "${PROJECT_DIR}/leanring-buddy"
fail_if_rg_matches "workerError\\.localizedDescription" "macOS UI does not display raw Worker error descriptions" "${PROJECT_DIR}/leanring-buddy/CompanionManager.swift" "${PROJECT_DIR}/leanring-buddy/CompanionManagerAccountActions.swift"
require_rg_match "accountVerificationFailureMessage" "macOS account errors use app-owned copy" "${PROJECT_DIR}/leanring-buddy/CompanionManagerAccountActions.swift"
require_rg_match "billingFailureMessage" "macOS billing errors use app-owned copy" "${PROJECT_DIR}/leanring-buddy/CompanionManagerAccountActions.swift"
require_rg_match "Do not pass user content" "SpiderDiagnostics documents content logging restrictions" "${PROJECT_DIR}/leanring-buddy/SpiderDiagnostics.swift"
require_rg_match "posixPermissions: 0o700" "Local Spider project directory uses owner-only permissions" "${PROJECT_DIR}/leanring-buddy/AdMissionDomain.swift"
require_rg_match "posixPermissions: 0o600" "Local Spider project file uses owner-only permissions" "${PROJECT_DIR}/leanring-buddy/AdMissionDomain.swift"
require_rg_match "maxGuideRequestBytes" "macOS app rejects oversized vision payloads before upload" "${VISION_GUIDE_CLIENT_SWIFT}"
require_rg_match "maxGuideResponseBytes" "macOS app limits Worker vision response size" "${VISION_GUIDE_CLIENT_SWIFT}"
require_rg_match "maxGuideScreenshotCount = 4" "macOS Vision client mirrors Worker screenshot-count limits" "${VISION_GUIDE_CONTRACTS_SWIFT}"
require_rg_match "boundedConversationHistory" "macOS Vision client trims conversation history before upload" "${VISION_GUIDE_CLIENT_SWIFT}"
require_rg_match "maxVisionHistoryTextCharacters" "macOS Vision client caps prior transcript text before upload" "${VISION_GUIDE_CONTRACTS_SWIFT}"
require_rg_match "struct AdMissionGuideSnapshot" "macOS Vision client uses a lightweight Ad Mission snapshot" "${PROJECT_DIR}/leanring-buddy/AdMissionDomain.swift" "${PROJECT_DIR}/leanring-buddy/SpiderVisionGuidePayload.swift"
require_rg_match "campaignDirection: CampaignDirection\\?" "macOS Ad Mission snapshot includes campaign direction" "${PROJECT_DIR}/leanring-buddy/AdMissionDomain.swift"
require_rg_match "adMissionSnapshot: adMissionSnapshot\\?\\.guideSnapshot\\(\\)" "macOS Vision client does not upload full local Ad Mission artifacts" "${VISION_GUIDE_CLIENT_SWIFT}"
fail_if_rg_matches "adMissionSnapshot: adMissionSnapshot$" "macOS Vision client does not send the raw AdMission payload" "${VISION_GUIDE_CLIENT_SWIFT}"
require_rg_match "cursorScreenMaxDimension = 2048" "macOS screen capture preserves higher detail on the cursor screen" "${PROJECT_DIR}/leanring-buddy/CompanionScreenCaptureUtility.swift"
require_rg_match "maxTotalJPEGBytes" "macOS screen capture keeps an in-memory JPEG payload budget" "${PROJECT_DIR}/leanring-buddy/CompanionScreenCaptureUtility.swift"
require_rg_match "maxScreenCaptures = SpiderContentLimits\\.maxGuideScreenshotCount" "macOS screen capture stops at the Worker screenshot limit" "${PROJECT_DIR}/leanring-buddy/CompanionScreenCaptureUtility.swift"
require_rg_match "remainingByteBudget" "macOS screen capture degrades or skips captures before exceeding payload budget" "${PROJECT_DIR}/leanring-buddy/CompanionScreenCaptureUtility.swift"
require_rg_match "enum CompanionScreenCaptureError" "macOS screen capture uses typed static errors" "${PROJECT_DIR}/leanring-buddy/CompanionScreenCaptureUtility.swift"
fail_if_rg_matches "NSError\\(" "macOS screen capture does not throw arbitrary NSError values" "${PROJECT_DIR}/leanring-buddy/CompanionScreenCaptureUtility.swift"
require_rg_match "enum SpiderGuideContextKind" "macOS app decodes guide context kinds through a closed enum" "${VISION_GUIDE_CONTRACTS_SWIFT}"
require_rg_match "contextKind: SpiderGuideContextKind" "macOS app rejects unknown guide context kinds during decode" "${VISION_GUIDE_CONTRACTS_SWIFT}"
fail_if_rg_matches "NSError\\(" "macOS Vision/project client uses typed static errors" "${VISION_GUIDE_CONTRACTS_SWIFT}" "${VISION_GUIDE_CLIENT_SWIFT}" "${VISION_GUIDE_SANITIZATION_SWIFT}"
require_rg_match "case missingSessionToken" "macOS Vision client has a typed missing-session error" "${VISION_GUIDE_CONTRACTS_SWIFT}"
check_vision_token_before_payload
require_rg_match "handleVisionClientError" "macOS app maps Vision client errors to app-owned UX" "${PROJECT_DIR}/leanring-buddy/CompanionManagerPresentationActions.swift" "${VISION_GUIDE_ACTIONS_SWIFT}"
require_rg_match "sanitizedForUse" "macOS app sanitizes structured guide responses before UI use" "${VISION_GUIDE_SANITIZATION_SWIFT}"
require_rg_match "guideResponse\\.point|let point: SpiderGuidePoint" "macOS app consumes pointing coordinates from structured guide responses" "${VISION_GUIDE_CONTRACTS_SWIFT}" "${VISION_GUIDE_ACTIONS_SWIFT}"
require_rg_match "streamingResponseText" "macOS app displays guidance text through the primary cursor overlay" "${PROJECT_DIR}/leanring-buddy/OverlayWindow.swift" "${PROJECT_DIR}/leanring-buddy/CompanionManager.swift"
fail_if_rg_matches "isClickyCursorEnabled" "macOS app does not keep legacy Clicky cursor preference fallback" "${PROJECT_DIR}/leanring-buddy/CompanionManager.swift"
require_rg_match "maxArtifactMarkdownCharacters" "macOS app caps persisted artifact markdown size" "${VISION_GUIDE_CONTRACTS_SWIFT}"
require_rg_match "maxProjectFileBytes" "macOS app caps local Spider project file size" "${VISION_GUIDE_CONTRACTS_SWIFT}"
require_rg_match "sanitizedForLocalStorage" "macOS app sanitizes local Spider project data before persistence" "${VISION_GUIDE_SANITIZATION_SWIFT}" "${PROJECT_DIR}/leanring-buddy/CompanionManager.swift"
require_rg_match "maxResponseBytes" "macOS auth client limits Worker response size" "${PROJECT_DIR}/leanring-buddy/SpiderAuthClient.swift"
require_rg_match "SpiderEmailAddressValidator" "macOS app validates login email addresses before Worker requests" "${PROJECT_DIR}/leanring-buddy/SpiderAuthClient.swift" "${PROJECT_DIR}/leanring-buddy/CompanionManagerAccountActions.swift"
require_rg_match "maxEmailCharacters" "macOS app caps login email length before Worker requests" "${PROJECT_DIR}/leanring-buddy/SpiderAuthClient.swift"
require_rg_match "unicodeScalars\\.allSatisfy" "macOS app rejects non-ASCII login email addresses before Worker requests" "${PROJECT_DIR}/leanring-buddy/SpiderAuthClient.swift"
require_rg_match "invalidEmail" "macOS auth client uses a typed invalid email error" "${PROJECT_DIR}/leanring-buddy/SpiderAuthClient.swift"
require_rg_match "normalizedLoginEmail" "macOS login UI uses shared email validation before enabling submit" "${PROJECT_DIR}/leanring-buddy/CompanionPanelView.swift"
require_rg_match "isLoginButtonEnabled = canSubmitEmail && !companionManager\\.isSubmittingLogin" "macOS login UI disables submit for invalid email addresses and in-flight login requests" "${PROJECT_DIR}/leanring-buddy/CompanionPanelView.swift"
require_rg_match "\\.disabled\\(!isLoginButtonEnabled\\)" "macOS login UI binds submit disabled state to validated email and loading state" "${PROJECT_DIR}/leanring-buddy/CompanionPanelView.swift"
require_rg_match "isSubmittingLogin" "macOS app tracks in-flight login requests" "${PROJECT_DIR}/leanring-buddy/CompanionManager.swift" "${PROJECT_DIR}/leanring-buddy/CompanionPanelView.swift"
require_rg_match "defer \\{ setLoginRequestInFlight\\(false\\) \\}" "macOS app clears in-flight login state after auth requests" "${PROJECT_DIR}/leanring-buddy/CompanionManagerAccountActions.swift"
require_rg_match "isOpeningCheckout" "macOS app tracks in-flight checkout requests" "${PROJECT_DIR}/leanring-buddy/CompanionManager.swift" "${PROJECT_DIR}/leanring-buddy/CompanionPanelView.swift"
require_rg_match "defer \\{ setCheckoutRequestInFlight\\(false\\) \\}" "macOS app clears in-flight checkout state after billing requests" "${PROJECT_DIR}/leanring-buddy/CompanionManagerAccountActions.swift"
require_rg_match "isOpeningBillingPortal" "macOS app tracks in-flight billing portal requests" "${PROJECT_DIR}/leanring-buddy/CompanionManager.swift" "${PROJECT_DIR}/leanring-buddy/CompanionPanelView.swift"
require_rg_match "defer \\{ setBillingPortalRequestInFlight\\(false\\) \\}" "macOS app clears in-flight billing portal state after billing requests" "${PROJECT_DIR}/leanring-buddy/CompanionManagerAccountActions.swift"
require_rg_match "isLoggingOut" "macOS app tracks in-flight logout requests" "${PROJECT_DIR}/leanring-buddy/CompanionManager.swift" "${PROJECT_DIR}/leanring-buddy/CompanionPanelView.swift"
require_rg_match "defer \\{ setLogoutRequestInFlight\\(false\\) \\}" "macOS app clears in-flight logout state after session revocation" "${PROJECT_DIR}/leanring-buddy/CompanionManagerAccountActions.swift"
require_rg_match "validatedBillingSession" "macOS app validates billing session URLs before opening them" "${PROJECT_DIR}/leanring-buddy/SpiderAuthClient.swift"
require_rg_match "invalidBillingURL" "macOS app rejects unsafe billing URLs" "${PROJECT_DIR}/leanring-buddy/SpiderAuthClient.swift"
require_rg_match "scheme\\?\\.lowercased\\(\\) == \"https\"" "macOS app requires HTTPS billing URLs" "${PROJECT_DIR}/leanring-buddy/SpiderAuthClient.swift"
require_rg_match "maxBillingURLCharacters" "macOS app caps Worker billing URL length" "${PROJECT_DIR}/leanring-buddy/SpiderAuthClient.swift"
require_rg_match "checkout\\.stripe\\.com" "macOS app opens only Stripe Checkout session URLs for checkout" "${PROJECT_DIR}/leanring-buddy/SpiderAuthClient.swift"
require_rg_match "billing\\.stripe\\.com" "macOS app opens only Stripe Billing Portal session URLs for portal" "${PROJECT_DIR}/leanring-buddy/SpiderAuthClient.swift"
require_rg_match "path\\.hasPrefix\\(expectedPathPrefix\\)" "macOS app validates Stripe billing URL path shape" "${PROJECT_DIR}/leanring-buddy/SpiderAuthClient.swift"
require_rg_match "response\\.url\\.port == nil" "macOS app rejects billing URLs with explicit ports" "${PROJECT_DIR}/leanring-buddy/SpiderAuthClient.swift"
require_rg_match "normalizedDeviceIdentifier" "macOS app normalizes Keychain device ids before sending them to the Worker" "${PROJECT_DIR}/leanring-buddy/SpiderSessionStore.swift"
require_rg_match "UUID\\(uuidString:" "macOS app rejects non-UUID device ids from Keychain" "${PROJECT_DIR}/leanring-buddy/SpiderSessionStore.swift"
require_rg_match "maxDeviceIdentifierCharacters" "macOS app caps local device id length to match Worker expectations" "${PROJECT_DIR}/leanring-buddy/SpiderSessionStore.swift"
require_rg_match "kSecAttrAccessibleWhenUnlockedThisDeviceOnly" "macOS Keychain tokens are available only while unlocked on this device" "${PROJECT_DIR}/leanring-buddy/SpiderSessionStore.swift"
require_rg_match "kSecAttrSynchronizable" "macOS Keychain tokens explicitly disable iCloud sync" "${PROJECT_DIR}/leanring-buddy/SpiderSessionStore.swift"
fail_if_rg_matches "kSecAttrAccessibleAfterFirstUnlock" "macOS Keychain tokens are not available after first unlock while locked" "${PROJECT_DIR}/leanring-buddy/SpiderSessionStore.swift"
fail_if_rg_matches "keychain(Read|Write|Delete)Failed\\(OSStatus\\)|Status:" "macOS Keychain errors do not carry raw OSStatus descriptions" "${PROJECT_DIR}/leanring-buddy/SpiderSessionStore.swift"
require_rg_match "SpiderWorkerTokenValidator" "macOS app uses a shared Worker token validator" "${PROJECT_DIR}/leanring-buddy/SpiderSessionStore.swift" "${PROJECT_DIR}/leanring-buddy/SpiderAuthClient.swift"
require_rg_match "feedbackEmailPattern" "macOS app validates configured feedback email" "${PROJECT_DIR}/leanring-buddy/AppBundleConfiguration.swift"
require_rg_match "feedbackMailURL" "macOS app builds feedback mailto URLs from validated components" "${PROJECT_DIR}/leanring-buddy/AppBundleConfiguration.swift" "${PROJECT_DIR}/leanring-buddy/CompanionPanelView.swift"
fail_if_rg_matches "URL\\(string: \"mailto:" "macOS app does not interpolate mailto URLs" "${PROJECT_DIR}/leanring-buddy/CompanionPanelView.swift"
require_rg_match "validatedWorkerBaseURL" "macOS app validates configured Worker base URL" "${PROJECT_DIR}/leanring-buddy/AppBundleConfiguration.swift"
require_rg_match "SpiderWorkerBaseURL must be configured" "macOS app fails closed when Worker base URL is missing" "${PROJECT_DIR}/leanring-buddy/AppBundleConfiguration.swift"
fail_if_rg_matches "spider-api\\.example\\.com" "macOS app does not fallback to an example Worker URL" "${PROJECT_DIR}/leanring-buddy/AppBundleConfiguration.swift"
require_rg_match "localDevelopmentHosts" "macOS app limits HTTP Worker URLs to local development hosts" "${PROJECT_DIR}/leanring-buddy/AppBundleConfiguration.swift"
require_rg_match "url\\.user == nil" "macOS app rejects Worker base URLs with embedded credentials" "${PROJECT_DIR}/leanring-buddy/AppBundleConfiguration.swift"
require_rg_match "url\\.query == nil" "macOS app rejects Worker base URLs with query strings" "${PROJECT_DIR}/leanring-buddy/AppBundleConfiguration.swift"
require_rg_match "url\\.path\\.isEmpty \\|\\| url\\.path == \"/\"" "macOS app treats Worker base URL as an origin" "${PROJECT_DIR}/leanring-buddy/AppBundleConfiguration.swift"
require_rg_match "SpiderWorkerBaseURL must use HTTPS outside local development" "macOS app requires HTTPS Worker URLs outside local development" "${PROJECT_DIR}/leanring-buddy/AppBundleConfiguration.swift"
require_rg_match "normalizedDoubleUUIDV4Token\\(developmentSessionToken\\)" "macOS app validates development session tokens before use" "${PROJECT_DIR}/leanring-buddy/AppBundleConfiguration.swift"
require_rg_match "tokenProvider\\(\\)\\.flatMap\\(SpiderWorkerTokenValidator.normalizedDoubleUUIDV4Token\\)" "macOS AI clients validate injected Worker tokens before sending them" "${VISION_GUIDE_CLIENT_SWIFT}" "${PROJECT_DIR}/leanring-buddy/OpenAIRealtimeVoiceClient.swift"
require_rg_match "normalizedDoubleUUIDV4Token\\(token\\)" "macOS app validates magic-link tokens before auth confirm requests" "${PROJECT_DIR}/leanring-buddy/SpiderAuthClient.swift"
require_rg_match "invalidMagicLinkToken" "macOS app rejects malformed magic links before hitting the Worker" "${PROJECT_DIR}/leanring-buddy/SpiderAuthClient.swift"
require_rg_match "magicLinkToken\\(from:" "macOS deep links are parsed through a dedicated magic-link validator" "${PROJECT_DIR}/leanring-buddy/CompanionManagerAccountActions.swift"
require_rg_match "queryItems\\.count == 1" "macOS magic-link deep links reject extra query parameters" "${PROJECT_DIR}/leanring-buddy/SpiderAccountSessionPolicy.swift"
require_rg_match "normalizedSessionToken" "macOS app validates Worker session tokens before storing or using them" "${PROJECT_DIR}/leanring-buddy/SpiderSessionStore.swift"
require_rg_match "doubleUUIDV4TokenPattern.*-4\\[0-9a-f\\]\\{3\\}.*\\[89ab\\]" "macOS app accepts only production-shaped Worker tokens" "${PROJECT_DIR}/leanring-buddy/SpiderSessionStore.swift"
require_rg_match "invalidSessionToken" "macOS app rejects malformed Worker session tokens instead of persisting them" "${PROJECT_DIR}/leanring-buddy/SpiderSessionStore.swift"
require_rg_match "case missingSessionToken" "macOS Realtime client has a typed missing-session error" "${PROJECT_DIR}/leanring-buddy/OpenAIRealtimeVoiceClient.swift"
check_realtime_token_before_secret_request
fail_if_rg_matches "NSError\\(" "macOS Realtime voice client uses typed static errors" "${PROJECT_DIR}/leanring-buddy/OpenAIRealtimeVoiceClient.swift"
require_rg_match "sign in again before using voice" "macOS voice UI maps missing Realtime session to login copy" "${PROJECT_DIR}/leanring-buddy/BuddyDictationManager.swift"
require_rg_match "maxClientSecretResponseBytes" "macOS Realtime client limits client-secret response size" "${PROJECT_DIR}/leanring-buddy/OpenAIRealtimeVoiceClient.swift"
require_rg_match "validatedAuthorizedSecretValue" "macOS app validates Worker-authorized Realtime client-secret values" "${PROJECT_DIR}/leanring-buddy/OpenAIRealtimeVoiceClient.swift"
require_rg_match "maxAuthorizedSecretCharacters" "macOS app caps Worker-authorized Realtime client-secret values" "${PROJECT_DIR}/leanring-buddy/OpenAIRealtimeVoiceClient.swift"
require_rg_match "authorizedSecretPattern" "macOS app restricts Worker-authorized Realtime client-secret characters" "${PROJECT_DIR}/leanring-buddy/OpenAIRealtimeVoiceClient.swift"
require_rg_match "validatedAuthorizedModelName" "macOS app validates Worker-authorized Realtime model names" "${PROJECT_DIR}/leanring-buddy/OpenAIRealtimeVoiceClient.swift"
require_rg_match "maxAuthorizedModelCharacters" "macOS app caps Worker-authorized Realtime model names" "${PROJECT_DIR}/leanring-buddy/OpenAIRealtimeVoiceClient.swift"
require_rg_match "authorizedModelNamePattern" "macOS app restricts Worker-authorized Realtime model characters" "${PROJECT_DIR}/leanring-buddy/OpenAIRealtimeVoiceClient.swift"
require_rg_match "maxServerEventTextBytes" "macOS Realtime clients limit server event size" "${PROJECT_DIR}/leanring-buddy/OpenAIRealtimeVoiceClient.swift" "${PROJECT_DIR}/leanring-buddy/OpenAIRealtimeTranscriptionProvider.swift"
require_rg_match "maxClientEventTextBytes" "macOS Realtime clients limit client event size" "${PROJECT_DIR}/leanring-buddy/OpenAIRealtimeVoiceClient.swift" "${PROJECT_DIR}/leanring-buddy/OpenAIRealtimeTranscriptionProvider.swift"
require_rg_match "case clientEventTooLarge" "macOS Realtime clients expose typed oversized-client-event errors" "${PROJECT_DIR}/leanring-buddy/OpenAIRealtimeVoiceClient.swift" "${PROJECT_DIR}/leanring-buddy/OpenAIRealtimeTranscriptionProvider.swift"
require_rg_match "maxTranscriptCharacters" "macOS Realtime transcription caps transcript length before guide use" "${PROJECT_DIR}/leanring-buddy/OpenAIRealtimeTranscriptionProvider.swift"
require_rg_match "sanitizedKeyterms" "macOS Realtime transcription sanitizes keyterms before prompt use" "${PROJECT_DIR}/leanring-buddy/OpenAIRealtimeTranscriptionProvider.swift"
fail_if_rg_matches "OpenAIRealtimeTranscriptionProviderError\\(message:" "macOS Realtime transcription uses typed static errors" "${PROJECT_DIR}/leanring-buddy/OpenAIRealtimeTranscriptionProvider.swift"
require_rg_match "voiceInputFailureMessage" "macOS voice UI maps known errors to app-owned copy" "${PROJECT_DIR}/leanring-buddy/BuddyDictationManager.swift"
require_rg_match "clientEventTooLarge" "macOS voice UI maps oversized Realtime client events to app-owned copy" "${PROJECT_DIR}/leanring-buddy/BuddyDictationManager.swift"
fail_if_rg_matches "LocalizedError|errorDescription" "macOS voice UI does not surface generic LocalizedError descriptions" "${PROJECT_DIR}/leanring-buddy/BuddyDictationManager.swift"
fail_if_rg_matches "TranscriptionProviderError\\(message:" "macOS transcription providers do not carry arbitrary error strings" "${PROJECT_DIR}/leanring-buddy/AppleSpeechTranscriptionProvider.swift" "${PROJECT_DIR}/leanring-buddy/OpenAIRealtimeTranscriptionProvider.swift"
fail_if_rg_matches "case assemblyAI|case openAI|assemblyai transcription request redirected" "macOS transcription factory does not keep legacy provider modes" "${PROJECT_DIR}/leanring-buddy/BuddyTranscriptionProvider.swift"
fail_if_rg_matches "auth/complete|path == \"complete\"|complete\\?sessionToken|queryValue\\(" "App does not accept legacy or generic-token deep links" "${PROJECT_DIR}/leanring-buddy" "${PROJECT_DIR}/README.md"
require_rg_match "speakPermissionsBlockedMessage" "App blocks guidance paths when required permissions are missing" "${PROJECT_DIR}/leanring-buddy/CompanionManagerPresentationActions.swift"
require_rg_match "screenGuidancePermissionReadiness" "App checks permissions before screen guidance paths" "${PROJECT_DIR}/leanring-buddy/CompanionManager.swift" "${PROJECT_DIR}/leanring-buddy/CompanionInteractionReadinessPolicy.swift"

echo
echo "Release tooling"
require_rg_match "SPIDER_APPCAST_URL" "Release config script requires a real Sparkle appcast URL" "${CONFIGURE_RELEASE}"
require_rg_match "SPIDER_WORKER_BASE_URL" "Release config script requires a real Worker base URL" "${CONFIGURE_RELEASE}"
require_rg_match "SPIDER_LOGIN_CONFIRM_URL" "Release config script requires a real magic-link confirm URL" "${CONFIGURE_RELEASE}"
require_rg_match "SPIDER_STRIPE_SUCCESS_URL" "Release config script requires a real Stripe success URL" "${CONFIGURE_RELEASE}"
require_rg_match "SPIDER_STRIPE_CANCEL_URL" "Release config script requires a real Stripe cancel URL" "${CONFIGURE_RELEASE}"
require_rg_match "SPIDER_D1_DATABASE_ID" "Release config script requires a real D1 database id" "${CONFIGURE_RELEASE}"
require_rg_match "SPIDER_CONFIGURE_DRY_RUN" "Release config script supports validation without rewriting files" "${CONFIGURE_RELEASE}"
require_rg_match "validate_d1_database_id" "Release config script validates D1 database id shape" "${CONFIGURE_RELEASE}"
require_rg_match "OPENAI_API_KEY" "Worker deploy preflight checks required secrets" "${WORKER_DEPLOY_PREFLIGHT}"
require_rg_match "typegen:check" "Worker deploy preflight checks generated binding scripts" "${WORKER_DEPLOY_PREFLIGHT}"
require_rg_match "check_migrations" "Worker deploy preflight checks D1 migrations" "${WORKER_DEPLOY_PREFLIGHT}"
require_rg_match "wrangler deploy --dry-run" "Worker deploy preflight checks dry-run deploy script" "${WORKER_DEPLOY_PREFLIGHT}" "${PROJECT_DIR}/worker/package.json"
require_rg_match "wrangler secret list --format json" "Worker remote preflight checks deployed secret names without values" "${WORKER_REMOTE_PREFLIGHT}"
require_rg_match "wrangler d1 migrations list DB --remote" "Worker remote preflight checks remote D1 migration status" "${WORKER_REMOTE_PREFLIGHT}"
require_rg_match "wrangler deploy --dry-run --outdir" "Worker remote preflight checks remote deploy dry run" "${WORKER_REMOTE_PREFLIGHT}"
check_release_preflight_order
if [ -n "${SPIDER_RELEASE_REPO:-}" ]; then
    ok "SPIDER_RELEASE_REPO is set"
else
    warn "SPIDER_RELEASE_REPO is not set. release.sh will refuse to publish until it is provided."
fi

if [ "${errors}" -gt 0 ]; then
    echo
    echo "Preflight failed: ${errors} error(s), ${warnings} warning(s)."
    exit 1
fi

echo
echo "Preflight passed: 0 error(s), ${warnings} warning(s)."
