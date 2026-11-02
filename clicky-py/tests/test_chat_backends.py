"""Tests for the chat backend layer (Claude via proxy / OpenAI direct) and
the mid-stream cancellation of the SSE parser."""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from clickpy.chat import (  # noqa: E402
    BACKEND_CLAUDE,
    BACKEND_OPENAI,
    available_models_for_backend,
    default_model_for_backend,
    resolve_chat_client,
)
from clickpy.claude_api import ClaudeAPI  # noqa: E402
from clickpy.config import CompanionSettings  # noqa: E402
from clickpy.openai_api import OpenAIAPI  # noqa: E402


def test_factory_defaults_to_claude_proxy():
    settings = CompanionSettings()
    client = resolve_chat_client(settings)
    assert isinstance(client, ClaudeAPI)
    assert client.proxy_url == "http://127.0.0.1:8787/chat"
    assert client.model == "claude-sonnet-4-6"


def test_factory_openai_requires_key_and_falls_back(monkeypatch):
    settings = CompanionSettings()
    settings.selected_chat_backend = BACKEND_OPENAI
    # No OPENAI_API_KEY in environment -> graceful fallback to Claude
    monkeypatch.delenv("OPENAI_API_KEY", raising=False)
    client = resolve_chat_client(settings)
    assert isinstance(client, ClaudeAPI)

    # With a key present -> the direct OpenAI client with the configured model
    monkeypatch.setenv("OPENAI_API_KEY", "sk-test")
    client = resolve_chat_client(settings)
    assert isinstance(client, OpenAIAPI)
    assert client.model == settings.selected_model


def test_model_lists_per_backend():
    settings = CompanionSettings()
    assert available_models_for_backend(settings, BACKEND_CLAUDE) == (
        "claude-sonnet-4-6",
        "claude-opus-4-6",
    )
    openai_models = available_models_for_backend(settings, BACKEND_OPENAI)
    assert openai_models[0] == "gpt-5.2-2025-12-11"
    assert default_model_for_backend(settings, BACKEND_OPENAI) == openai_models[0]


class _FakeOpenAIResponse:
    status_code = 200

    def __init__(self, payload):
        self._payload = payload
        self.text = "unused"

    def json(self):
        return self._payload


class _FakeOpenAIClient:
    """Captures the posted JSON so request shape can be asserted offline."""

    def __init__(self, payload):
        self._payload = payload
        self.posted_body = None

    def post(self, url, headers=None, json=None):
        assert "api.openai.com/v1/chat/completions" in url
        assert headers["Authorization"] == "Bearer sk-test"
        self.posted_body = json
        return _FakeOpenAIResponse({**self._payload, "_posted": json})


def test_openai_vision_request_shape():
    client = OpenAIAPI(api_key="sk-test")
    fake = _FakeOpenAIClient(
        {"choices": [{"message": {"content": "pointed it out [POINT:none]"}}]}
    )

    text, _duration = client.analyze_image(
        images=[(b"\xff\xd8\xff\xe0jpeg-data", "user's screen (cursor is here)")],
        system_prompt="be clicky",
        conversation_history=[("earlier q", "earlier a")],
        user_prompt="where is the button",
        http_client=fake,
    )

    assert text == "pointed it out [POINT:none]"

    body = fake.posted_body
    assert body["model"] == "gpt-5.2-2025-12-11"
    assert body["max_completion_tokens"] == 600
    messages = body["messages"]
    assert messages[0]["role"] == "system"
    assert messages[1:3] == [
        {"role": "user", "content": "earlier q"},
        {"role": "assistant", "content": "earlier a"},
    ]
    current = messages[3]
    blocks = current["content"]
    assert blocks[0]["type"] == "text"
    image_block = blocks[1]
    assert image_block["type"] == "image_url"
    assert image_block["image_url"]["url"].startswith("data:image/jpeg;base64,")
    assert blocks[-1]["text"] == "where is the button"


class _FakeStreamingResponse:
    def __init__(self, lines):
        self._lines = lines

    def iter_lines(self):
        return iter(self._lines)


def test_sse_parser_cancels_midstream():
    lines = [
        'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"start "}}',
        'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"more"}}',
        'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"NEVER"}}',
    ]

    cancellation_switch = {"cancelled": False}

    def on_text_chunk(_accumulated):
        cancellation_switch["cancelled"] = True  # cancel after first chunk

    try:
        ClaudeAPI._consume_sse_stream(
            _FakeStreamingResponse(lines),
            on_text_chunk,
            is_cancelled_fn=lambda: cancellation_switch["cancelled"],
        )
        raise AssertionError("expected RuntimeError for cancellation")
    except RuntimeError as cancellation_error:
        assert "cancelled" in str(cancellation_error)


def test_sse_parser_runs_when_never_cancelled():
    lines = [
        'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hello"}}',
    ]
    accumulated = ClaudeAPI._consume_sse_stream(
        _FakeStreamingResponse(lines), None, is_cancelled_fn=lambda: False
    )
    assert accumulated == "hello"
