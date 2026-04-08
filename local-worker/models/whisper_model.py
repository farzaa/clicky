"""
Whisper model: MLX-Whisper base

Uses soundfile to decode WAV bytes → numpy array and passes the array
directly to mlx_whisper.transcribe(), which accepts np.ndarray.
This avoids any ffmpeg dependency.
"""

import asyncio
import io

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
                import numpy as np

                # 1 second of silence at 16kHz — enough to trigger model
                # download and load without needing ffmpeg
                silent = np.zeros(16000, dtype=np.float32)
                mlx_whisper.transcribe(silent, path_or_hf_repo=MODEL_REPO)
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

        Decodes the WAV with soundfile (no ffmpeg needed) into a float32
        numpy array and passes it directly to mlx_whisper.transcribe().

        Returns:
            Transcribed text string
        """
        if not self.is_ready():
            raise RuntimeError("Whisper model is not ready")

        loop = asyncio.get_event_loop()

        def _transcribe():
            import numpy as np
            import soundfile as sf

            audio_np, sample_rate = sf.read(io.BytesIO(wav_bytes), dtype="float32")

            # Whisper expects mono; average channels if stereo
            if audio_np.ndim > 1:
                audio_np = audio_np.mean(axis=1)

            result = mlx_whisper.transcribe(audio_np, path_or_hf_repo=MODEL_REPO)
            return result["text"].strip()

        return await loop.run_in_executor(None, _transcribe)


# Global singleton
_whisper_model_instance = WhisperModel()


async def initialize_whisper_model():
    await _whisper_model_instance.initialize()


def get_whisper_model() -> WhisperModel:
    return _whisper_model_instance
