Dev mode: unlimited (local testing only)
=====================================

This worker supports a development mock mode that returns fake streaming
responses for `/chat`. This is useful for local testing and for trying the
app without consuming real Anthropic / ElevenLabs credits.

How to enable
--------------

- Locally with `wrangler dev` (example):

```bash
cd worker
DEV_UNLIMITED=true npx wrangler dev
```

- Or set the `DEV_UNLIMITED` variable in your Cloudflare Worker environment.

Client (macOS app) configuration
--------------------------------

The macOS app can be pointed at a local dev worker by setting a UserDefaults
string `devWorkerBaseURL`. For example, to use `http://127.0.0.1:8787` run:

```bash
defaults write com.your.bundle.identifier devWorkerBaseURL "http://127.0.0.1:8787"
```

Then start the app — it will pick up the override and send `/chat` requests to
the local worker.

What it does
------------

- When `DEV_UNLIMITED=true`, the `/chat` route returns a small Server-Sent
  Events (SSE) stream that mimics Anthropic `content_block_delta` text chunks.
- This lets the macOS app render progressive responses without calling the
  real Anthropic API.

Security & Ethics
-----------------

This mode is only intended for local development and testing. Do not use it to
bypass paid subscriptions, nor enable it in production or shared deployments.
