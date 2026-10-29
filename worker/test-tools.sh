#!/usr/bin/env bash
# Smoke test for /chat-tools against `wrangler dev`.
#
# Usage:
#   1. In one terminal:  cd worker && npx wrangler dev
#   2. In another:       ./test-tools.sh
#
# Expects worker/.dev.vars to have real ANTHROPIC_API_KEY and COMPOSIO_API_KEY
# values. The Composio user "clicky-smoketest" should have at least one
# toolkit linked (e.g. `composio link gmail --user-id clicky-smoketest`)
# for the tool-call branch to do anything interesting; otherwise the model
# will just respond in plain text.

set -euo pipefail

WORKER_URL="${WORKER_URL:-http://localhost:8787}"
USER_ID="${USER_ID:-clicky-smoketest}"

echo "→ POST ${WORKER_URL}/chat-tools  (x-clicky-user-id: ${USER_ID})"
echo

curl -sS -X POST "${WORKER_URL}/chat-tools" \
  -H "Content-Type: application/json" \
  -H "x-clicky-user-id: ${USER_ID}" \
  -d '{
    "model": "claude-sonnet-4-6",
    "max_tokens": 1024,
    "system": "You are Clicky, a helpful AI buddy with access to tools. Use tools when the user asks you to take an action; otherwise reply in one or two sentences.",
    "messages": [
      { "role": "user", "content": "What tools do you have access to right now? List a couple of them by name." }
    ]
  }' | jq .
