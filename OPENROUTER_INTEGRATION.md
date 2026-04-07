# OpenRouter Integration for Clicky

## Overview

Add [OpenRouter](https://openrouter.ai) as a third LLM provider alongside the existing `ClaudeAPI` and `OpenAIAPI` implementations. OpenRouter provides a unified API that gives access to 100+ models (including Claude, GPT-4, Gemini, Llama, etc.) through a single endpoint.

## Why OpenRouter

- **Model flexibility** — users can switch between Claude Sonnet, Opus, GPT-4o, Gemini, etc. without changing providers
- **Cost control** — users pick price/performance tradeoffs per task
- **Single API key** — one key for all models instead of separate Anthropic/OpenAI keys
- **Usage tracking** — unified dashboard for spend across models
- **Fallback models** — automatic failover if primary model is down

## API Compatibility

OpenRouter uses the OpenAI chat completions format with minor differences:

```
POST https://openrouter.ai/api/v1/chat/completions
Authorization: Bearer <OPENROUTER_API_KEY>
```

### Required Headers

```http
Authorization: Bearer sk-or-v1-xxxxx
HTTP-Referer: https://github.com/farzaa/clicky  # optional, for rankings
X-Title: Clicky                                   # optional, for rankings
```

### Request Body

```json
{
  "model": "anthropic/claude-sonnet-4",
  "messages": [
    {"role": "user", "content": "..."}
  ],
  "stream": true,
  "max_tokens": 4096,
  "temperature": 0.7
}
```

### Model ID Format

OpenRouter uses `provider/model-name` format:
- `anthropic/claude-sonnet-4`
- `anthropic/claude-opus-4`
- `openai/gpt-4o`
- `google/gemini-2.5-pro-preview`
- `meta-llama/llama-4-maverick`

## Implementation Spec

### 1. New Class: `OpenRouterAPI`

```swift
class OpenRouterAPI {
    static let baseURL = "https://openrouter.ai/api/v1"
    var apiKey: String
    var model: String  // e.g. "anthropic/claude-sonnet-4"
    
    func chat(messages: [Message], stream: Bool = true) async throws -> ...
    func listModels() async throws -> [Model]
}
```

### 2. Settings UI Changes

Add a provider selector in preferences:
- Anthropic (existing) — requires `ANTHROPIC_API_KEY`
- OpenAI (existing) — requires `OPENAI_API_KEY`
- OpenRouter (new) — requires `OPENROUTER_API_KEY` + model selector

### 3. Model Picker

When OpenRouter is selected, show a searchable dropdown of available models fetched from `GET /api/v1/models`. Cache the list locally, refresh on settings open.

### 4. API Key Storage

Store `OPENROUTER_API_KEY` in Keychain alongside existing keys. Same security model as current implementation.

### 5. Streaming

OpenRouter supports SSE streaming identical to OpenAI's format. Reuse the existing `OpenAIAPI` streaming parser with minimal changes (different response chunk structure but same event format).

## Request/Response Differences from Native APIs

| Feature | Anthropic Native | OpenAI Native | OpenRouter |
|---------|-----------------|---------------|------------|
| Endpoint | `/v1/messages` | `/v1/chat/completions` | `/v1/chat/completions` |
| Auth header | `x-api-key` | `Authorization: Bearer` | `Authorization: Bearer` |
| Streaming | SSE with `data:` | SSE with `data:` | Same as OpenAI |
| Model param | `model` | `model` | `model` (provider/model format) |
| System prompt | `system` field | `messages[0].role=system` | Same as OpenAI |

## Testing Checklist

- [ ] API key validation (invalid key, expired key, rate limited)
- [ ] Streaming responses render correctly in UI
- [ ] Model switching mid-conversation works
- [ ] Error handling for model-specific limits (context window, etc.)
- [ ] Keychain storage/retrieval of OpenRouter key
- [ ] Settings UI persists provider selection
- [ ] Fallback behavior when OpenRouter is down

## Migration Path

Users currently on Anthropic/OpenAI native APIs should not be affected. OpenRouter is additive. Users can optionally migrate to OpenRouter for consolidated billing but native APIs remain fully functional.

## Cost Transparency

Display estimated cost per request in the UI when using OpenRouter (the API returns usage stats in responses). This is a nice-to-have, not MVP.

## Notes

- OpenRouter has rate limits per model — surface these in error messages
- Some models don't support vision/multimodal — filter model list based on capabilities
- OpenRouter charges a small markup (typically 0-10%) over native API pricing
