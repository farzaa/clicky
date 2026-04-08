"""
Whisper model: MLX-Whisper base
"""

import asyncio
import tempfile
from pathlib import Path

try:
    import mlx_whisper
except ImportError:
    mlx_whisper = None

MODEL_REPO = "mlx-community/whisper-base-mlx"


class WhisperModel:
    """Singleton wrapper for MLX-Whisper base model."""

    _instance = None
    _ready = False

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
        return cls._instance

    async def initialize(self):
        """Warm up the model so the first real transcription isn't slow."""
        if self._ready:
            return

        loop = asyncio.get_event_loop()

        def _warmup():
            try:
                # Create a tiny silent WAV to force model download + load
                import numpy as np
                import soundfile as sf

                silent = np.zeros(16000, dtype=np.float32)  # 1 second of silence
                with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
                    tmp = f.name
                    sf.write(tmp, silent, 16000)

                mlx_whisper.transcribe(tmp, path_or_hf_repo=MODEL_REPO)
                Path(tmp).unlink(missing_ok=True)
                return True
            except Exception as e:
                print(f"❌ Failed to warm up Whisper model: {e}")
                return False

        try:
            self._ready = await loop.run_in_executor(None, _warmup)
            if self._ready:
                print("✅ Whisper model (base) loaded")
        except Exception as e:
            print(f"❌ Whisper model initialization failed: {e}")
            self._ready = False

    def is_ready(self) -> bool:
        return self._ready

    async def transcribe_wav_bytes(self, wav_bytes: bytes) -> str:
        """
        Transcribe WAV audio bytes.

        Returns:
            Transcribed text string
        """
        if not self.is_ready():
            raise RuntimeError("Whisper model is not ready")

        loop = asyncio.get_event_loop()

        def _transcribe():
            # Write bytes to temp file (mlx_whisper expects a file path)
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
                tmp = f.name
                f.write(wav_bytes)

            try:
                result = mlx_whisper.transcribe(tmp, path_or_hf_repo=MODEL_REPO)
                return result["text"].strip()
            finally:
                Path(tmp).unlink(missing_ok=True)

        return await loop.run_in_executor(None, _transcribe)


# Global singleton
_whisper_model_instance = WhisperModel()


async def initialize_whisper_model():
    await _whisper_model_instance.initialize()


def get_whisper_model() -> WhisperModel:
    return _whisper_model_instance
