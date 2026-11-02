"""OpenAI API helper for vision analysis — port of OpenAIAPI.swift.

Like the Swift version, this client talks to OpenAI DIRECTLY (not through
the Worker proxy, which only fronts Claude). The Swift app reads its key
from the app bundle; on Windows the equivalent source is the
OPENAI_API_KEY environment variable. Non-streaming, same response shape.
"""

from __future__ import annotations

import time
from typing import Callable, Optional


def base64_encode(data: bytes) -> str:
    import base64

    return base64.b64encode(data).decode("ascii")


class OpenAIAPI:
    def __init__(self, api_key: str, model: str = "gpt-5.2-2025-12-11"):
        self.api_key = api_key
        self.api_url = "https://api.openai.com/v1/chat/completions"
        self.model = model

    @classmethod
    def from_environment(cls, model: str = "gpt-5.2-2025-12-11") -> "OpenAIAPI":
        """Builds the client from OPENAI_API_KEY — the Windows stand-in for
        the app bundle's hardcoded key."""
        import os

        api_key = os.environ.get("OPENAI_API_KEY")
        if not api_key:
            raise RuntimeError(
                "OPENAI_API_KEY is not set in the environment — cannot use "
                "the OpenAI chat backend."
            )
        return cls(api_key=api_key, model=model)

    def analyze_image(
        self,
        images: list[tuple[bytes, str]],
        system_prompt: str,
        conversation_history: list[tuple[str, str]],
        user_prompt: str,
        on_text_chunk: Optional[Callable[[str], None]] = None,
        http_client=None,
        is_cancelled_fn: Optional[Callable[[], bool]] = None,
    ) -> tuple[str, float]:
        """Sends a vision request to OpenAI with one or more labeled images.

        The signature matches ClaudeAPI.analyze_image_streaming so the two
        chat backends are interchangeable inside CompanionManager. OpenAI's
        mac client is non-streaming, so the full text reaches on_text_chunk
        exactly once, after the complete response arrives."""
        start_time = time.monotonic()

        # Build messages array: system message first, then history, then the
        # current message with all labeled images + prompt (same as Swift).
        messages: list[dict] = [{"role": "system", "content": system_prompt}]

        for user_placeholder, assistant_response in conversation_history:
            messages.append({"role": "user", "content": user_placeholder})
            messages.append({"role": "assistant", "content": assistant_response})

        content_blocks: list[dict] = []
        for image_data, image_label in images:
            content_blocks.append({"type": "text", "text": image_label})
            content_blocks.append(
                {
                    "type": "image_url",
                    "image_url": {
                        # Screen captures are JPEG; the data URI hardcodes it
                        # exactly like the Swift client.
                        "url": "data:image/jpeg;base64," + base64_encode(image_data),
                    },
                }
            )
        content_blocks.append({"type": "text", "text": user_prompt})
        messages.append({"role": "user", "content": content_blocks})

        body = {
            "model": self.model,
            # max_tokens is deprecated/incompatible for some newer OpenAI models.
            "max_completion_tokens": 600,
            "messages": messages,
        }
        payload_mb = len(str(body).encode("utf-8")) / 1_048_576.0
        print(f"🌐 OpenAI request: {payload_mb:.1f}MB, {len(images)} image(s)")

        # A client we constructed here is closed in the finally block; an
        # injected one (tests) stays under its owner's control.
        owns_client = http_client is None
        if http_client is None:
            import httpx  # lazily so pure-Python tests skip the dependency

            http_client = httpx.Client(timeout=httpx.Timeout(120.0, read=300.0))

        try:
            response = http_client.post(
                self.api_url,
                headers={
                    "Authorization": f"Bearer {self.api_key}",
                    "content-type": "application/json",
                },
                json=body,
            )
            status_code = int(response.status_code)
            if not (200 <= status_code < 300):
                error_text = getattr(response, "text", "Unknown error")
                raise RuntimeError(f"API Error ({status_code}): {error_text}")

            if is_cancelled_fn is not None and is_cancelled_fn():
                raise RuntimeError("response cancelled")

            json_body = response.json()
            choices = json_body.get("choices") or []
            if not choices:
                raise RuntimeError("Invalid response format")
            message_block = choices[0].get("message") or {}
            text = message_block.get("content")
            if text is None:
                raise RuntimeError("Invalid response format")

            if on_text_chunk is not None:
                on_text_chunk(text)
        finally:
            if owns_client:
                http_client.close()

        duration = time.monotonic() - start_time
        return text, duration
