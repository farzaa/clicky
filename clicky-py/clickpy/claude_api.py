"""Claude vision API client with SSE streaming — port of ClaudeAPI.swift.

All requests go through the Cloudflare Worker proxy so no API key ships
with the app. The request/response shape (messages array, labeled images,
content_block_delta SSE parsing) matches the Swift implementation exactly.
The URLSession-level TLS warmup optimization is intentionally NOT ported:
Python's httpx reuses connection pools automatically and the macOS TLS
session ticket issue it works around does not exist here.
"""

from __future__ import annotations

import json
import time
from typing import Callable, Iterable, Optional


def detect_image_media_type(image_data: bytes) -> str:
    """Detects the MIME type of image data by inspecting the first bytes.
    Screen captures from mss are JPEG, but pasted images from the clipboard
    can be PNG. The API rejects requests where the declared media_type
    doesn't match the actual image format."""
    if len(image_data) >= 4 and image_data[0:4] == b"\x89\x50\x4e\x47":
        return "image/png"
    # Default to JPEG — screen captures use JPEG compression
    return "image/jpeg"


class ClaudeAPI:
    def __init__(self, proxy_url: str, model: str = "claude-sonnet-4-6"):
        self.proxy_url = proxy_url
        self.model = model

    @staticmethod
    def _build_messages(
        images: Iterable[tuple[bytes, str]],
        conversation_history: Iterable[tuple[str, str]],
        user_prompt: str,
    ) -> list:
        """Builds the messages array: history first, then the current message
        with all labeled images + prompt. Same layout as Swift."""
        messages = []

        for user_placeholder, assistant_response in conversation_history:
            messages.append({"role": "user", "content": user_placeholder})
            messages.append({"role": "assistant", "content": assistant_response})

        content_blocks = []
        for image_data, image_label in images:
            content_blocks.append(
                {
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": detect_image_media_type(image_data),
                        "data": base64_encode(image_data),
                    },
                }
            )
            content_blocks.append({"type": "text", "text": image_label})
        content_blocks.append({"type": "text", "text": user_prompt})
        messages.append({"role": "user", "content": content_blocks})
        return messages

    def analyze_image_streaming(
        self,
        images: list[tuple[bytes, str]],
        system_prompt: str,
        conversation_history: list[tuple[str, str]],
        user_prompt: str,
        on_text_chunk: Callable[[str], None],
        http_client=None,
    ) -> tuple[str, float]:
        """Sends a vision request to Claude with streaming. Calls
        `on_text_chunk` with the accumulated text each time new text arrives
        (progressive display). Returns (full text, duration) when done."""
        return self._analyze(
            images=images,
            system_prompt=system_prompt,
            conversation_history=conversation_history,
            user_prompt=user_prompt,
            max_tokens=1024,
            streaming=True,
            on_text_chunk=on_text_chunk,
            http_client=http_client,
        )

    def analyze_image(
        self,
        images: list[tuple[bytes, str]],
        system_prompt: str,
        conversation_history: list[tuple[str, str]],
        user_prompt: str,
        http_client=None,
    ) -> tuple[str, float]:
        """Non-streaming fallback for validation-style requests."""
        return self._analyze(
            images=images,
            system_prompt=system_prompt,
            conversation_history=conversation_history,
            user_prompt=user_prompt,
            max_tokens=256,
            streaming=False,
            on_text_chunk=None,
            http_client=http_client,
        )

    def _analyze(
        self,
        images,
        system_prompt,
        conversation_history,
        user_prompt,
        max_tokens,
        streaming,
        on_text_chunk,
        http_client,
    ) -> tuple[str, float]:
        import httpx  # imported lazily so pure-Python tests skip the dependency

        start_time = time.monotonic()
        body = {
            "model": self.model,
            "max_tokens": max_tokens,
            "stream": streaming,
            "system": system_prompt,
            "messages": self._build_messages(images, conversation_history, user_prompt),
        }
        request_headers = {
            "content-type": "application/json",
            "accept": "text/event-stream" if streaming else "application/json",
        }

        client_closed_here = False
        if http_client is None:
            http_client = httpx.Client(timeout=httpx.Timeout(120.0, read=300.0))
            client_closed_here = True

        try:
            if streaming:
                # httpx streaming: client.stream context manager + iter_lines
                with http_client.stream(
                    "POST", self.proxy_url, headers=request_headers, json=body
                ) as response:
                    self._raise_for_error(response, streaming=True)
                    accumulated_text = self._consume_sse_stream(response, on_text_chunk)
            else:
                response = http_client.post(
                    self.proxy_url, headers=request_headers, json=body
                )
                try:
                    self._raise_for_error(response, streaming=False)
                    json_body = response.json()
                    content_blocks = json_body.get("content", [])
                    text_blocks = [b for b in content_blocks if b.get("type") == "text"]
                    if not text_blocks or "text" not in text_blocks[0]:
                        raise RuntimeError("Invalid response format")
                    accumulated_text = text_blocks[0]["text"]
                finally:
                    response.close()
        finally:
            if client_closed_here:
                http_client.close()

        duration = time.monotonic() - start_time
        return accumulated_text, duration

    @staticmethod
    def _raise_for_error(response, streaming: bool) -> None:
        """If non-2xx status, read the full body as error text, like Swift."""
        if 200 <= response.status_code < 300:
            return
        if streaming:
            response.read()
        error_body = response.text
        raise RuntimeError(f"API Error ({response.status_code}): {error_body}")

    @staticmethod
    def _consume_sse_stream(response, on_text_chunk: Optional[Callable[[str], None]]) -> str:
        """Parses the SSE stream — each event is "data: {json}\\n\\n". We care
        about content_block_delta events carrying text_delta payloads.
        Extracted as a static method so it is unit-testable with a fake
        line stream (no network)."""
        accumulated_response_text = ""
        for line in response.iter_lines():
            # httpx yields decoded str lines without the trailing newline
            if not line or not line.startswith("data: "):
                continue
            json_string = line[len("data: "):]
            if json_string == "[DONE]":
                break
            try:
                event_payload = json.loads(json_string)
            except json.JSONDecodeError:
                continue
            event_type = event_payload.get("type")
            if event_type == "content_block_delta":
                delta = event_payload.get("delta") or {}
                if delta.get("type") == "text_delta" and "text" in delta:
                    accumulated_response_text += delta["text"]
                    if on_text_chunk is not None:
                        on_text_chunk(accumulated_response_text)
        return accumulated_response_text


def base64_encode(data: bytes) -> str:
    import base64

    return base64.b64encode(data).decode("ascii")
