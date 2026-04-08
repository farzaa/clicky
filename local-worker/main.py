"""
Local FastAPI backend for Clicky.
Replaces Anthropic Claude, ElevenLabs TTS, and AssemblyAI STT with local models.

Three endpoints:
- POST /chat: Claude-compatible vision API with SSE streaming
- POST /tts: ElevenLabs-compatible TTS API, returns WAV
- POST /transcribe: Whisper transcription from WAV upload
"""

import asyncio
import json
from typing import AsyncGenerator

from fastapi import FastAPI, File, HTTPException, Request, UploadFile
from fastapi.responses import Response, StreamingResponse
from starlette.middleware.cors import CORSMiddleware

from models.vision_model import (
    get_vision_model,
    initialize_vision_model,
)
from models.tts_model import (
    get_tts_model,
    initialize_tts_model,
)
from models.whisper_model import (
    get_whisper_model,
    initialize_whisper_model,
)

app = FastAPI(title="Clicky Local Backend")

# Allow the local Swift app to connect without CORS issues
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Model initialization state
_models_initializing = True
_initialization_complete = False


@app.on_event("startup")
async def startup_event():
    """Initialize all models on app startup."""
    global _models_initializing, _initialization_complete

    print("\n🚀 Clicky Local Backend starting...")
    print("📦 Loading models in parallel...\n")

    try:
        await asyncio.gather(
            initialize_vision_model(),
            initialize_tts_model(),
            initialize_whisper_model(),
        )
    except Exception as e:
        print(f"\n❌ Unexpected error during model initialization: {e}\n")
    finally:
        _initialization_complete = True
        _models_initializing = False

    vision_ok = get_vision_model().is_ready()
    tts_ok = get_tts_model().is_ready()
    whisper_ok = get_whisper_model().is_ready()

    if vision_ok and tts_ok and whisper_ok:
        print("\n✨ All models ready! Server is operational.\n")
    else:
        not_ready = [
            name for name, ok in
            [("vision", vision_ok), ("tts", tts_ok), ("whisper", whisper_ok)]
            if not ok
        ]
        print(f"\n⚠️  Server started but these models failed to load: {', '.join(not_ready)}")
        print("   Those endpoints will return 503. Run setup_models.py if you haven't yet.\n")


def require_models_ready():
    """Raise 503 if models aren't loaded yet."""
    if _models_initializing or not _initialization_complete:
        raise HTTPException(status_code=503, detail="Models still initializing, try again in a moment")

    vision = get_vision_model()
    tts = get_tts_model()
    whisper = get_whisper_model()

    if not (vision.is_ready() and tts.is_ready() and whisper.is_ready()):
        raise HTTPException(status_code=503, detail="Some models are not ready")


@app.post("/chat")
async def chat(request: Request):
    """
    Chat endpoint compatible with Anthropic API format.

    Streams SSE in Anthropic format:
      data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"..."}}
      data: {"type":"message_stop"}
      data: [DONE]
    """
    require_models_ready()

    body = await request.json()
    vision_model = get_vision_model()

    # Extract base64 images from Anthropic message format
    images = []
    for msg in body.get("messages", []):
        content = msg.get("content", [])
        if isinstance(content, list):
            for item in content:
                if item.get("type") == "image":
                    source = item.get("source", {})
                    if source.get("type") == "base64":
                        images.append(source.get("data", ""))

    system_prompt = body.get("system", "You are a helpful assistant.")

    async def stream_response() -> AsyncGenerator[str, None]:
        try:
            async for chunk in vision_model.generate_response_stream(
                images, system_prompt, body.get("messages", [])
            ):
                if chunk:
                    delta = {
                        "type": "content_block_delta",
                        "delta": {"type": "text_delta", "text": chunk},
                    }
                    yield f"data: {json.dumps(delta)}\n\n"

            # End-of-stream markers that ClaudeAPI.swift expects
            yield 'data: {"type":"message_stop"}\n\n'
            yield "data: [DONE]\n\n"
        except Exception as e:
            error_event = {"type": "error", "error": {"message": str(e)}}
            yield f"data: {json.dumps(error_event)}\n\n"
            yield "data: [DONE]\n\n"

    return StreamingResponse(stream_response(), media_type="text/event-stream")


@app.post("/tts")
async def tts(request: Request):
    """
    TTS endpoint compatible with ElevenLabs API format.

    Accepts JSON: {"text": "...", "model_id": "...", "voice_settings": {...}}
    Returns: WAV audio bytes
    """
    require_models_ready()

    body = await request.json()
    text = body.get("text", "")
    if not text:
        raise HTTPException(status_code=400, detail="text field is required")

    tts_model = get_tts_model()
    wav_bytes = await tts_model.generate_speech_wav_bytes(text)

    return Response(content=wav_bytes, media_type="audio/wav")


@app.post("/transcribe")
async def transcribe(file: UploadFile = File(...)):
    """
    Whisper transcription endpoint.

    Accepts: multipart/form-data with field 'file' (WAV audio)
    Returns: {"text": "transcribed text here"}
    """
    require_models_ready()

    wav_bytes = await file.read()
    if not wav_bytes:
        raise HTTPException(status_code=400, detail="No audio data provided")

    whisper_model = get_whisper_model()
    text = await whisper_model.transcribe_wav_bytes(wav_bytes)

    return {"text": text}


@app.get("/health")
async def health():
    """Health check endpoint."""
    return {
        "status": "ok" if _initialization_complete else "initializing",
        "models": {
            "vision": get_vision_model().is_ready(),
            "tts": get_tts_model().is_ready(),
            "whisper": get_whisper_model().is_ready(),
        },
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="127.0.0.1", port=8787, log_level="info")
