#!/usr/bin/env python3
"""
Clicky OpenRouter Proxy

Translates Anthropic Messages API calls to OpenRouter (OpenAI-compatible) format.
Run this locally, then set Clicky's Anthropic endpoint to http://localhost:8976

Usage:
    export OPENROUTER_API_KEY=sk-or-v1-xxxxx
    python3 proxy.py

Then in Clicky, set custom Anthropic endpoint to: http://localhost:8976
"""

import json
import os
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.request import Request, urlopen
from urllib.error import HTTPError
import threading

OPENROUTER_BASE = "https://openrouter.ai/api/v1"
DEFAULT_MODEL = "anthropic/claude-sonnet-4"

# set this to use a specific model regardless of what clicky requests
# e.g. "openai/gpt-4o", "google/gemini-2.5-pro-preview", "meta-llama/llama-4-maverick"
# leave empty to use the MODEL_MAP lookup (anthropic models only)
DEFAULT_MODEL = os.environ.get("OPENROUTER_MODEL", "")

# model mapping: anthropic model name -> openrouter model id
# only used when DEFAULT_MODEL is empty
MODEL_MAP = {
    "claude-sonnet-4-20250514": "anthropic/claude-sonnet-4",
    "claude-sonnet-4": "anthropic/claude-sonnet-4",
    "claude-opus-4-20250514": "anthropic/claude-opus-4",
    "claude-opus-4": "anthropic/claude-opus-4",
    "claude-3-5-sonnet-20241022": "anthropic/claude-3.5-sonnet",
    "claude-3-5-sonnet-20240620": "anthropic/claude-3.5-sonnet",
    "claude-3-opus-20240229": "anthropic/claude-3-opus",
    "claude-3-sonnet-20240229": "anthropic/claude-3-sonnet",
    "claude-3-haiku-20240307": "anthropic/claude-3-haiku",
}

FALLBACK_MODEL = "anthropic/claude-sonnet-4"


def anthropic_to_openai(anthropic_req):
    """Convert Anthropic Messages API request to OpenAI chat completions format."""
    messages = []

    # system message
    if "system" in anthropic_req:
        messages.append({
            "role": "system",
            "content": anthropic_req["system"]
        })

    # convert messages
    for msg in anthropic_req.get("messages", []):
        role = msg["role"]
        content = msg.get("content", "")

        # handle multimodal content (list of blocks)
        if isinstance(content, list):
            openai_content = []
            for block in content:
                if block.get("type") == "text":
                    openai_content.append({
                        "type": "text",
                        "text": block["text"]
                    })
                elif block.get("type") == "image":
                    openai_content.append({
                        "type": "image_url",
                        "image_url": {
                            "url": f"data:{block['source']['media_type']};base64,{block['source']['data']}"
                        }
                    })
            messages.append({"role": role, "content": openai_content})
        else:
            messages.append({"role": role, "content": content})

    # map model: env override > anthropic map > fallback
    anthropic_model = anthropic_req.get("model", "")
    if DEFAULT_MODEL:
        model = DEFAULT_MODEL
    else:
        model = MODEL_MAP.get(anthropic_model, FALLBACK_MODEL)

    # build openai request
    openai_req = {
        "model": model,
        "messages": messages,
        "max_tokens": anthropic_req.get("max_tokens", 4096),
        "stream": anthropic_req.get("stream", False),
    }

    if "temperature" in anthropic_req:
        openai_req["temperature"] = anthropic_req["temperature"]

    return openai_req


def openai_to_anthropic_stream(chunk_data, model):
    """Convert OpenAI streaming chunk to Anthropic SSE format."""
    if not chunk_data.strip():
        return ""

    if chunk_data.strip() == "data: [DONE]":
        return "event: message_stop\ndata: {}\n\n"

    if not chunk_data.startswith("data: "):
        return ""

    try:
        data = json.loads(chunk_data[6:])
        choice = data.get("choices", [{}])[0]
        delta = choice.get("delta", {})
        content = delta.get("content", "")
        finish_reason = choice.get("finish_reason")

        parts = []

        if content:
            block_delta = {
                "type": "content_block_delta",
                "index": 0,
                "delta": {
                    "type": "text_delta",
                    "text": content
                }
            }
            parts.append(f"event: content_block_delta\ndata: {json.dumps(block_delta)}\n\n")

        if finish_reason == "stop":
            parts.append("event: message_stop\ndata: {}\n\n")

        return "".join(parts)

    except (json.JSONDecodeError, KeyError, IndexError):
        return ""


def openai_to_anthropic_response(openai_resp, model):
    """Convert OpenAI response to Anthropic Messages format."""
    choice = openai_resp.get("choices", [{}])[0]
    message = choice.get("message", {})
    content_text = message.get("content", "")
    usage = openai_resp.get("usage", {})

    return {
        "id": openai_resp.get("id", "msg_or_xxx"),
        "type": "message",
        "role": "assistant",
        "model": model,
        "content": [
            {
                "type": "text",
                "text": content_text
            }
        ],
        "stop_reason": "end_turn",
        "stop_sequence": None,
        "usage": {
            "input_tokens": usage.get("prompt_tokens", 0),
            "output_tokens": usage.get("completion_tokens", 0)
        }
    }


class ProxyHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        print(f"[proxy] {args[0]}")

    def do_get(self):
        if self.path == "/v1/models":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "data": [
                    {"id": k, "name": v} for k, v in MODEL_MAP.items()
                ]
            }).encode())
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == "/v1/messages":
            self.handle_messages()
        else:
            self.send_response(404)
            self.end_headers()

    def handle_messages(self):
        api_key = os.environ.get("OPENROUTER_API_KEY")
        if not api_key:
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "error": "OPENROUTER_API_KEY not set"
            }).encode())
            return

        # read request
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)
        anthropic_req = json.loads(body)

        # convert
        openai_req = anthropic_to_openai(anthropic_req)
        wants_stream = openai_req.get("stream", False)
        model = openai_req["model"]

        # forward to openrouter
        headers = {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "HTTP-Referer": "https://github.com/farzaa/clicky",
            "X-Title": "Clicky",
        }

        req = Request(
            f"{OPENROUTER_BASE}/chat/completions",
            data=json.dumps(openai_req).encode(),
            headers=headers,
            method="POST"
        )

        try:
            if wants_stream:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "keep-alive")
                self.end_headers()

                # send message_start
                start_event = {
                    "type": "message_start",
                    "message": {
                        "id": "msg_or_xxx",
                        "type": "message",
                        "role": "assistant",
                        "model": anthropic_req.get("model", "claude"),
                        "content": [],
                        "stop_reason": None,
                        "stop_sequence": None,
                        "usage": {"input_tokens": 0, "output_tokens": 0}
                    }
                }
                self.wfile.write(f"event: message_start\ndata: {json.dumps(start_event)}\n\n".encode())
                self.wfile.flush()

                # send content_block_start
                block_start = {
                    "type": "content_block_start",
                    "index": 0,
                    "content_block": {"type": "text", "text": ""}
                }
                self.wfile.write(f"event: content_block_start\ndata: {json.dumps(block_start)}\n\n".encode())
                self.wfile.flush()

                # stream from openrouter
                with urlopen(req, timeout=120) as resp:
                    for line in resp:
                        line_str = line.decode("utf-8")
                        converted = openai_to_anthropic_stream(line_str, model)
                        if converted:
                            self.wfile.write(converted.encode())
                            self.wfile.flush()

            else:
                with urlopen(req, timeout=120) as resp:
                    openai_resp = json.loads(resp.read())

                anthropic_resp = openai_to_anthropic_response(openai_resp, model)

                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(anthropic_resp).encode())

        except HTTPError as e:
            self.send_response(e.code)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            error_body = e.read().decode()
            self.wfile.write(json.dumps({
                "error": f"OpenRouter error: {error_body}"
            }).encode())

        except Exception as e:
            self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({
                "error": str(e)
            }).encode())


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8976
    server = HTTPServer(("127.0.0.1", port), ProxyHandler)
    print(f"clicky openrouter proxy running on http://127.0.0.1:{port}")
    print(f"set clicky's anthropic endpoint to: http://localhost:{port}")
    print(f"OPENROUTER_API_KEY: {'set' if os.environ.get('OPENROUTER_API_KEY') else 'NOT SET'}")
    print(f"OPENROUTER_MODEL: {DEFAULT_MODEL or f'map from clicky (fallback: {FALLBACK_MODEL})'}")
    print()
    print("popular models:")
    print("  openai/gpt-4o                    openai/gpt-4o-mini")
    print("  google/gemini-2.5-pro-preview    google/gemini-2.0-flash")
    print("  anthropic/claude-sonnet-4        anthropic/claude-opus-4")
    print("  meta-llama/llama-4-maverick      deepseek/deepseek-chat-v3")
    print()
    print("full list: https://openrouter.ai/models")
    print()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nshutting down")
        server.shutdown()


if __name__ == "__main__":
    main()
