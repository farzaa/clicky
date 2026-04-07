# Clicky OpenRouter Proxy

Local proxy that lets Clicky use any model via OpenRouter instead of just Anthropic.

## How it works

Clicky speaks Anthropic API. OpenRouter speaks OpenAI API. This proxy translates between them.

```
Clicky → (Anthropic API) → this proxy → (OpenAI API) → OpenRouter → 100+ models
```

## Setup

```bash
# 1. install (nothing to install, just python3)
# 2. set your openrouter key
export OPENROUTER_API_KEY=sk-or-v1-xxxxx

# 3. run the proxy
python3 proxy.py
```

Output:
```
clicky openrouter proxy running on http://127.0.0.1:8976
set clicky's anthropic endpoint to: http://localhost:8976
OPENROUTER_API_KEY: set
```

## Configure Clicky

Set Clicky's Anthropic endpoint to: `http://localhost:8976`

Leave your Anthropic API key blank (the proxy uses your OpenRouter key).

## Supported models

Clicky's model name gets mapped automatically:

| Clicky model | OpenRouter model |
|-------------|-----------------|
| claude-sonnet-4 | anthropic/claude-sonnet-4 |
| claude-opus-4 | anthropic/claude-opus-4 |
| claude-3-5-sonnet | anthropic/claude-3.5-sonnet |
| claude-3-opus | anthropic/claude-3-opus |
| claude-3-haiku | anthropic/claude-3-haiku |

Default: `anthropic/claude-sonnet-4`

Edit `MODEL_MAP` in proxy.py to add/change mappings.

## Features

- Streaming support (SSE)
- System prompt handling
- Multimodal (images) passthrough
- Model name auto-mapping
- Error forwarding from OpenRouter

## Custom port

```bash
python3 proxy.py 9000
```
