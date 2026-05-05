# Clicky Codex GPT-5.5 OAuth Proxy

Local companion proxy for the Clicky fork that swaps the chat model from Anthropic Claude to `gpt-5.5` through Codex/ChatGPT OAuth.

This proxy intentionally runs on your Mac, not Cloudflare Workers, because Codex OAuth credentials live in `~/.codex/auth.json` and must never be deployed to a third-party edge worker.

## Prerequisites

- Node.js `20+`
- Codex CLI authenticated with ChatGPT OAuth: `codex login`
- A valid `~/.codex/auth.json` with `auth_mode: "chatgpt"`
- Existing Clicky Cloudflare Worker can still be used for `/tts` and `/transcribe-token`, or you can point this proxy at it for fallback routes.

## Run

```bash
cd codex-gpt55-proxy
CLICKY_UPSTREAM_WORKER_URL="https://your-existing-clicky-worker.workers.dev" npm start
```

The proxy listens on `http://127.0.0.1:8787` by default. Configure the Clicky app chat proxy URL to:

```text
http://127.0.0.1:8787/chat
```

Optional environment variables:

- `PORT`: listen port, default `8787`
- `CODEX_AUTH_FILE`: path to Codex auth JSON, default `~/.codex/auth.json`
- `CODEX_MODEL`: model slug, default `gpt-5.5`
- `CLICKY_UPSTREAM_WORKER_URL`: forwards `/tts` and `/transcribe-token` to your existing Clicky worker
- `CODEX_UPSTREAM_URL`: default `https://chatgpt.com/backend-api/codex/responses`

## Notes

- The proxy accepts Clicky's existing Anthropic-style `/chat` request body and returns Anthropic-style SSE events, so the Swift app needs minimal changes.
- It refreshes ChatGPT OAuth tokens by shelling out to `codex debug models` when the token is stale or when the upstream returns `401`.
- Treat `~/.codex/auth.json` like a password.
