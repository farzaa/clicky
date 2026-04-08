#!/usr/bin/env python3
"""
Auto-download and setup for local models on first run.
Downloads models to ~/.clicky-local/models/
"""

import urllib.request
from pathlib import Path

from huggingface_hub import snapshot_download


MODELS_DIR = Path.home() / ".clicky-local" / "models"

# Kokoro ONNX model files from the official GitHub release
KOKORO_ONNX_URL = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx"
KOKORO_VOICES_URL = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin"


def _download_file(url: str, dest: Path):
    """Download a file with a simple progress indicator."""
    print(f"    → {dest.name} ... ", end="", flush=True)
    urllib.request.urlretrieve(url, dest)
    size_mb = dest.stat().st_size / (1024 * 1024)
    print(f"{size_mb:.1f} MB")


def setup_models():
    """Download required models for the local worker."""
    MODELS_DIR.mkdir(parents=True, exist_ok=True)

    print("🤖 Setting up local models...\n")

    # ── Vision model (Qwen2.5-VL-7B 4-bit MLX) ──────────────────────────────
    vision_model_path = MODELS_DIR / "qwen-vlm"
    if not vision_model_path.exists():
        print("📥 Downloading Qwen2.5-VL-7B-Instruct-4bit (~5.5 GB)...")
        snapshot_download(
            "mlx-community/Qwen2.5-VL-7B-Instruct-4bit",
            local_dir=str(vision_model_path),
            repo_type="model",
        )
        print("✅ Vision model ready\n")
    else:
        print("✅ Vision model already cached\n")

    # ── Whisper (MLX-Whisper base) ───────────────────────────────────────────
    whisper_model_path = MODELS_DIR / "whisper-base"
    if not whisper_model_path.exists():
        print("📥 Downloading whisper-base-mlx (~290 MB)...")
        snapshot_download(
            "mlx-community/whisper-base-mlx",
            local_dir=str(whisper_model_path),
            repo_type="model",
        )
        print("✅ Whisper model ready\n")
    else:
        print("✅ Whisper model already cached\n")

    # ── Kokoro TTS ONNX files ────────────────────────────────────────────────
    kokoro_dir = MODELS_DIR / "kokoro"
    kokoro_dir.mkdir(parents=True, exist_ok=True)

    onnx_path = kokoro_dir / "kokoro-v1.0.onnx"
    voices_path = kokoro_dir / "voices-v1.0.bin"

    needs_download = not onnx_path.exists() or not voices_path.exists()
    if needs_download:
        print("📥 Downloading Kokoro-82M ONNX model files...")
        if not onnx_path.exists():
            _download_file(KOKORO_ONNX_URL, onnx_path)
        if not voices_path.exists():
            _download_file(KOKORO_VOICES_URL, voices_path)
        print("✅ Kokoro TTS model ready\n")
    else:
        print("✅ Kokoro TTS model already cached\n")

    print("✨ All models downloaded!")
    print(f"   Location: {MODELS_DIR}")


if __name__ == "__main__":
    setup_models()
