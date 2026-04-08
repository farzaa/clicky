"""
Vision model: Qwen2.5-VL-7B-Instruct via mlx-vlm
"""

import asyncio
import base64
import io
from typing import AsyncGenerator

from PIL import Image

try:
    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template
    from mlx_vlm.utils import load_config
except ImportError:
    load = None
    stream_generate = None
    apply_chat_template = None
    load_config = None

MODEL_PATH = "mlx-community/Qwen2.5-VL-7B-Instruct-4bit"


class VisionModel:
    """Singleton wrapper for Qwen2.5-VL-7B-Instruct vision model."""

    _instance = None
    _model = None
    _processor = None
    _config = None
    _ready = False

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance

    async def initialize(self):
        """Load model on startup in background."""
        if self._ready:
            return

        loop = asyncio.get_event_loop()

        def _load():
            try:
                model, processor = load(MODEL_PATH)
                config = load_config(MODEL_PATH)
                return model, processor, config
            except Exception as e:
                print(f"❌ Failed to load vision model: {e}")
                return None, None, None

        try:
            self._model, self._processor, self._config = await loop.run_in_executor(
                None, _load
            )
            self._ready = self._model is not None
            if self._ready:
                print("✅ Vision model (Qwen2.5-VL-7B) loaded")
        except Exception as e:
            print(f"❌ Vision model initialization failed: {e}")
            self._ready = False

    def is_ready(self) -> bool:
        return self._ready and self._model is not None

    async def generate_response_stream(
        self, images: list[str], system_prompt: str, messages: list[dict]
    ) -> AsyncGenerator[str, None]:
        """
        Stream a vision-language response.

        Args:
            images: Base64-encoded images extracted from the Anthropic request
            system_prompt: System instruction from the request
            messages: Full Anthropic-format message list

        Yields:
            Incremental text chunks
        """
        if not self.is_ready():
            raise RuntimeError("Vision model is not ready")

        # Decode base64 images to PIL
        pil_images = []
        for img_b64 in images:
            try:
                img_bytes = base64.b64decode(img_b64)
                pil_images.append(Image.open(io.BytesIO(img_bytes)))
            except Exception as e:
                print(f"⚠️ Failed to decode image: {e}")

        # Build the user text from all text blocks in the last user message
        user_text_parts = []
        for msg in messages:
            if msg.get("role") != "user":
                continue
            content = msg.get("content", [])
            if isinstance(content, list):
                for block in content:
                    if block.get("type") == "text":
                        user_text_parts.append(block["text"])
            elif isinstance(content, str):
                user_text_parts.append(content)

        user_prompt = "\n".join(user_text_parts) if user_text_parts else ""

        # Prepend system prompt so the model sees it as context
        full_prompt = f"{system_prompt}\n\n{user_prompt}" if system_prompt else user_prompt

        # Format with the model's chat template (handles Qwen VL image tokens)
        formatted_prompt = apply_chat_template(
            self._processor,
            self._config,
            full_prompt,
            num_images=len(pil_images),
        )

        # Run the blocking stream_generate in a thread so we don't block the
        # event loop.  We collect chunks from a queue.
        chunk_queue: asyncio.Queue[str | None] = asyncio.Queue()
        loop = asyncio.get_event_loop()

        def _run_generate():
            try:
                for result in stream_generate(
                    self._model,
                    self._processor,
                    formatted_prompt,
                    image=pil_images if pil_images else None,
                    max_tokens=512,
                ):
                    if result.text:
                        # Put chunks into the queue from the worker thread
                        loop.call_soon_threadsafe(chunk_queue.put_nowait, result.text)
            except Exception as e:
                print(f"❌ Stream generation error: {e}")
            finally:
                loop.call_soon_threadsafe(chunk_queue.put_nowait, None)  # sentinel

        # Start generation in background thread
        asyncio.get_event_loop().run_in_executor(None, _run_generate)

        # Yield chunks as they arrive
        while True:
            chunk = await chunk_queue.get()
            if chunk is None:
                break
            yield chunk


# Global singleton
_vision_model_instance = VisionModel()


async def initialize_vision_model():
    await _vision_model_instance.initialize()


def get_vision_model() -> VisionModel:
    return _vision_model_instance
