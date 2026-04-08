"""
TTS model: Kokoro-82M ONNX
"""

import asyncio
import io
from pathlib import Path

try:
    from kokoro_onnx import Kokoro
except ImportError:
    Kokoro = None

# Model files are downloaded by setup_models.py to this location
_KOKORO_DIR = Path.home() / ".clicky-local" / "models" / "kokoro"
_ONNX_PATH = _KOKORO_DIR / "kokoro-v1.0.onnx"
_VOICES_PATH = _KOKORO_DIR / "voices-v1.0.bin"


class TTSModel:
    """Singleton wrapper for Kokoro-82M ONNX TTS model."""

    _instance = None
    _model = None
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
            if not _ONNX_PATH.exists() or not _VOICES_PATH.exists():
                print(
                    f"❌ Kokoro model files not found at {_KOKORO_DIR}\n"
                    "   Run: python setup_models.py"
                )
                return None
            try:
                return Kokoro(str(_ONNX_PATH), str(_VOICES_PATH))
            except Exception as e:
                print(f"❌ Failed to load TTS model: {e}")
                return None

        try:
            self._model = await loop.run_in_executor(None, _load)
            self._ready = self._model is not None
            if self._ready:
                print("✅ TTS model (Kokoro-82M) loaded")
        except Exception as e:
            print(f"❌ TTS model initialization failed: {e}")
            self._ready = False

    def is_ready(self) -> bool:
        return self._ready and self._model is not None

    async def generate_speech_wav_bytes(self, text: str) -> bytes:
        """
        Generate speech from text.

        Returns:
            WAV audio bytes (24000 Hz, mono, float32 → int16 WAV)
        """
        if not self.is_ready():
            raise RuntimeError("TTS model is not ready")

        loop = asyncio.get_event_loop()

        def _synthesize():
            import soundfile as sf

            samples, sample_rate = self._model.create(text, voice="af_heart", speed=1.0, lang="en-us")
            wav_buffer = io.BytesIO()
            sf.write(wav_buffer, samples, sample_rate, format="WAV")
            return wav_buffer.getvalue()

        return await loop.run_in_executor(None, _synthesize)


# Global singleton
_tts_model_instance = TTSModel()


async def initialize_tts_model():
    await _tts_model_instance.initialize()


def get_tts_model() -> TTSModel:
    return _tts_model_instance
