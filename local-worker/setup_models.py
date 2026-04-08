#!/usr/bin/env python3
"""
Auto-download and setup for local models on first run.
Downloads models to ~/.clicky-local/models/
"""

import os
from pathlib import Path
from huggingface_hub import snapshot_download


def setup_models():
    """Download required models for the local worker."""
    models_dir = Path.home() / ".clicky-local" / "models"
    models_dir.mkdir(parents=True, exist_ok=True)

    print("🤖 Setting up local models...")

    # Vision model
    vision_model_path = models_dir / "qwen-vlm"
    if not vision_model_path.exists():
        print("📥 Downloading Qwen2.5-VL-7B-Instruct-4bit (~5.5 GB)...")
        snapshot_download(
            "mlx-community/Qwen2.5-VL-7B-Instruct-4bit",
            local_dir=str(vision_model_path),
            repo_type="model",
        )
        print("✅ Vision model ready")
    else:
        print("✅ Vision model already cached")

    # Whisper model
    whisper_model_path = models_dir / "whisper-base"
    if not whisper_model_path.exists():
        print("📥 Downloading Whisper-base (~290 MB)...")
        snapshot_download(
            "mlx-community/whisper-base-mlx",
            local_dir=str(whisper_model_path),
            repo_type="model",
        )
        print("✅ Whisper model ready")
    else:
        print("✅ Whisper model already cached")

    # Kokoro TTS model (bundled with kokoro-onnx package, no separate download)
    print("✅ Kokoro TTS model bundled with kokoro-onnx package")

    print("\n✨ All models ready!")


if __name__ == "__main__":
    setup_models()
