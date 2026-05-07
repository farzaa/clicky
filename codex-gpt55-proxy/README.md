# Clicky Codex GPT-5.5 OAuth Proxy

Local companion proxy for the Clicky fork that swaps the chat model from Anthropic Claude to `gpt-5.5` through Codex/ChatGPT OAuth.

This proxy intentionally runs on your Mac, not Cloudflare Workers, because Codex OAuth credentials live in `~/.codex/auth.json` and must never be deployed to a third-party edge worker.

## Prerequisites

- Node.js `20+`
- Codex CLI authenticated with ChatGPT OAuth: `codex login`
- A valid `~/.codex/auth.json` with `auth_mode: "chatgpt"`
- Deepgram API key for local `/transcribe` and `/tts` routes.

## Run

```bash
cd codex-gpt55-proxy
cp .env.example .env
# Edit .env and set DEEPGRAM_API_KEY. Optional: DEEPGRAM_STT_MODEL, DEEPGRAM_TTS_MODEL, DEEPGRAM_TTS_ENCODING.
npm start
```

The proxy listens on `http://127.0.0.1:8877` by default. Configure the Clicky app chat proxy URL to:

```text
http://127.0.0.1:8877/chat
```

Optional environment variables:

- `PORT`: listen port, default `8877`
- `CODEX_AUTH_FILE`: path to Codex auth JSON, default `~/.codex/auth.json`
- `CODEX_MODEL`: model slug, default `gpt-5.5`
- `CODEX_UPSTREAM_URL`: default `https://chatgpt.com/backend-api/codex/responses`
- `DEEPGRAM_API_KEY`: required for `/transcribe` and `/tts` unless Agent Vault broker settings are configured
- `DEEPGRAM_STT_MODEL`: optional Deepgram Listen model, default `nova-3`
- `DEEPGRAM_TTS_MODEL`: optional Deepgram Speak voice/model, default `aura-2-thalia-en`
- `DEEPGRAM_TTS_ENCODING`: optional audio encoding, default `mp3`
- `AGENT_VAULT_ADDR`, `AGENT_VAULT_TOKEN`, `AGENT_VAULT_VAULT`, `AGENT_VAULT_CA_FILE`: optional Agent Vault broker settings for Deepgram credentials

## Notes

- The proxy accepts Clicky's existing Anthropic-style `/chat` request body and returns Anthropic-style SSE events, so the Swift app needs minimal changes.
- It refreshes ChatGPT OAuth tokens by shelling out to `codex debug models` when the token is stale or when the upstream returns `401`.
- Treat `~/.codex/auth.json` like a password.
