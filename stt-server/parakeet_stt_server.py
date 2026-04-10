"""
Parakeet STT WebSocket Server — audio frames in, transcript JSON out.

Protocol:
  - Client connects to ws://localhost:{PORT}
  - Client sends binary frames (WebM/Opus from MediaRecorder)
  - Server decodes via ffmpeg, runs VAD + Parakeet transcription
  - Server sends JSON: {"text": "...", "final": true/false}
  - One connection = one session. Disconnect to reset.

Environment:
  PARAKEET_MODEL_DIR  — path to sherpa-onnx model directory
  PARAKEET_STT_PORT   — listen port (default 9200)
"""

import asyncio
import json
import logging
import os
import signal
import subprocess
import sys

import numpy as np
import sherpa_onnx
import websockets

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("parakeet-stt")

MODEL_DIR = os.path.join(
    os.environ["PARAKEET_MODEL_DIR"],
    "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8",
)
VAD_MODEL = os.path.join(os.environ["PARAKEET_MODEL_DIR"], "silero_vad.onnx")
PORT = int(os.environ.get("PARAKEET_STT_PORT", "9200"))
SAMPLE_RATE = 16000


def create_recognizer():
    return sherpa_onnx.OfflineRecognizer.from_transducer(
        encoder=os.path.join(MODEL_DIR, "encoder.int8.onnx"),
        decoder=os.path.join(MODEL_DIR, "decoder.int8.onnx"),
        joiner=os.path.join(MODEL_DIR, "joiner.int8.onnx"),
        tokens=os.path.join(MODEL_DIR, "tokens.txt"),
        model_type="nemo_transducer",
        provider="cuda",
        num_threads=2,
        sample_rate=SAMPLE_RATE,
        feature_dim=80,
    )


def create_vad():
    config = sherpa_onnx.VadModelConfig()
    config.silero_vad.model = VAD_MODEL
    config.silero_vad.min_silence_duration = 0.25
    config.silero_vad.min_speech_duration = 0.1
    config.silero_vad.threshold = 0.5
    config.sample_rate = SAMPLE_RATE
    return sherpa_onnx.VoiceActivityDetector(config, buffer_size_in_seconds=60)


def decode_webm_to_pcm(webm_bytes):
    """Decode WebM/Opus audio to float32 PCM at 16kHz mono via ffmpeg."""
    proc = subprocess.run(
        [
            "ffmpeg",
            "-hide_banner",
            "-loglevel", "error",
            "-f", "webm",
            "-i", "pipe:",
            "-f", "f32le",
            "-ar", str(SAMPLE_RATE),
            "-ac", "1",
            "pipe:",
        ],
        input=webm_bytes,
        capture_output=True,
    )
    if proc.returncode != 0:
        stderr = proc.stderr.decode("utf-8", errors="replace").strip()
        log.warning("ffmpeg decode failed: %s", stderr)
        return np.array([], dtype=np.float32)

    return np.frombuffer(proc.stdout, dtype=np.float32)


def transcribe_segment(recognizer, samples):
    """Run offline recognition on a single speech segment."""
    stream = recognizer.create_stream()
    stream.accept_waveform(SAMPLE_RATE, samples)
    recognizer.decode_streams([stream])
    return stream.result.text.strip()


async def handle_session(websocket, recognizer):
    """Handle one STT session (one WebSocket connection)."""
    vad = create_vad()
    leftover = np.array([], dtype=np.float32)
    log.info("Session started from %s", websocket.remote_address)

    try:
        async for message in websocket:
            if not isinstance(message, bytes):
                continue

            samples = decode_webm_to_pcm(message)
            if len(samples) == 0:
                continue

            if len(leftover) > 0:
                samples = np.concatenate([leftover, samples])

            window_size = 512
            n_complete = (len(samples) // window_size) * window_size
            for i in range(0, n_complete, window_size):
                vad.accept_waveform(samples[i : i + window_size])

            leftover = samples[n_complete:]

            while not vad.empty():
                segment = vad.front
                vad.pop()
                seg_samples = np.array(segment.samples, dtype=np.float32)
                text = transcribe_segment(recognizer, seg_samples)
                if text:
                    log.info("Transcript: %s", text)
                    await websocket.send(json.dumps({"text": text, "final": True}))

    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        while not vad.empty():
            segment = vad.front
            vad.pop()
            seg_samples = np.array(segment.samples, dtype=np.float32)
            text = transcribe_segment(recognizer, seg_samples)
            if text:
                try:
                    await websocket.send(json.dumps({"text": text, "final": True}))
                except websockets.exceptions.ConnectionClosed:
                    pass

        log.info("Session ended")


async def main():
    recognizer = create_recognizer()
    log.info("Model loaded from %s", MODEL_DIR)
    log.info("Listening on ws://localhost:%d", PORT)

    stop = asyncio.get_event_loop().create_future()
    for sig in (signal.SIGTERM, signal.SIGINT):
        asyncio.get_event_loop().add_signal_handler(sig, stop.set_result, None)

    async with websockets.serve(
        lambda ws: handle_session(ws, recognizer),
        "localhost",
        PORT,
        max_size=2**20,
    ):
        await stop


if __name__ == "__main__":
    asyncio.run(main())
