"""Voice transcription providers — port of the transcription provider layer
(BuddyTranscriptionProvider.swift + AssemblyAI + OpenAI providers).

Structure mirrors the Swift pluggable layer:
- TranscriptionProvider (protocol): startStreamingSession -> session object
- AssemblyAIStreamingTranscriptionProvider: websocket streaming via the
  Cloudflare Worker's short-lived tokens
- OpenAIAudioTranscriptionProvider: push-to-talk audio buffered locally,
  uploaded as WAV on release
- Windows has no Apple Speech framework, so the AppleSpeech provider is not
  ported; the factory falls back to OpenAI instead.

Callbacks arrive on provider background threads. The CompanionManager
marshals everything onto the Qt main thread through signals, exactly like
the MainActor hop in Swift. All websocket I/O runs on one shared asyncio
loop thread, reproducing the Swift "single shared URLSession" rule: reusing
the same connection owner across rapid reconnections keeps sockets healthy.
"""

from __future__ import annotations

import asyncio
import json
import threading
from concurrent.futures import Future
from typing import Callable, Optional

try:  # keep the module importable for pure-Python tests
    import websockets
except ImportError:  # pragma: no cover
    websockets = None

from concurrent.futures import TimeoutError as _FutureTimeout


class TranscriptionProviderError(Exception):
    """Raised for session failures — same role as the Swift error struct."""


class TranscriptionProvider:
    """Protocol surface. A provider returns a streaming session on start."""

    display_name = "Provider"

    def start_streaming_session(
        self,
        keyterms: list[str],
        on_transcript_update: Callable[[str], None],
        on_final_transcript_ready: Callable[[str], None],
        on_error: Callable[[Exception], None],
    ) -> "StreamingTranscriptionSession":
        raise NotImplementedError


class StreamingTranscriptionSession:
    """Protocol surface for an active dictation session."""

    def append_audio_buffer(self, pcm16_bytes: bytes) -> None:
        raise NotImplementedError

    def request_final_transcript(self) -> None:
        raise NotImplementedError

    def cancel(self) -> None:
        raise NotImplementedError


def _run_coroutine_on_shared_loop(coro, loop_thread: "_WebsocketLoopThread", timeout: float):
    future = loop_thread.submit_coroutine(coro)
    try:
        return future.result(timeout=timeout)
    except _FutureTimeout as timeout_error:
        future.cancel()
        raise TranscriptionProviderError(
            f"Transcription session timed out after {timeout}s."
        ) from timeout_error


class AssemblyAIStreamingTranscriptionProvider(TranscriptionProvider):
    """Streaming transcription provider backed by AssemblyAI's websocket API.

    Ports AssemblyAIStreamingTranscriptionProvider.swift + its private
    session class, including the turn-based transcript bookkeeping
    (storedTurnTranscriptsByOrder, formatted-turn preference, the 1.4 s
    explicit-final grace deadline, and delivering the best partial
    transcript if the websocket errors mid-session)."""

    websocket_base_url = "wss://streaming.assemblyai.com/v3/ws"
    target_sample_rate = 16_000
    explicit_final_transcript_grace_period_seconds = 1.4
    final_transcript_fallback_delay_seconds = 2.8

    def __init__(self, proxy_base_url: str):
        self.transcribe_token_proxy_url = f"{proxy_base_url.rstrip('/')}/transcribe-token"
        # One long-lived loop thread shared across all streaming sessions.
        # Creating a fresh event loop (.JOptionPane owner) per session — the
        # Swift comment about corrupting the OS connection pool applies to
        # websockets too: TLS teardown races cause "Socket is not connected".
        self._loop_thread: Optional[_WebsocketLoopThread] = None
        self._loop_thread_lock = threading.Lock()

    def _shared_loop_thread(self) -> "_WebsocketLoopThread":
        with self._loop_thread_lock:
            if self._loop_thread is None:
                self._loop_thread = _WebsocketLoopThread(start_it=True)
            elif not self._loop_thread.is_alive():
                raise TranscriptionProviderError(
                    "AssemblyAI websocket loop thread died unexpectedly."
                )
            return self._loop_thread

    def start_streaming_session(
        self,
        keyterms: list[str],
        on_transcript_update: Callable[[str], None],
        on_final_transcript_ready: Callable[[str], None],
        on_error: Callable[[Exception], None],
    ) -> StreamingTranscriptionSession:
        temporary_token = self._fetch_temporary_token()
        session = _AssemblyAIStreamingTranscriptionSession(
            temporary_token=temporary_token,
            loop_thread=self._shared_loop_thread(),
            keyterms=keyterms,
            on_transcript_update=on_transcript_update,
            on_final_transcript_ready=on_final_transcript_ready,
            on_error=on_error,
        )
        session.open()
        return session

    def _fetch_temporary_token(self) -> str:
        import httpx

        # Called on the caller's thread; a session is started per push, so a
        # short blocking request here is fine (Swift does the same, just async).
        response = httpx.post(self.transcribe_token_proxy_url, timeout=15.0)
        if not (200 <= response.status_code < 300):
            raise TranscriptionProviderError(
                f"Failed to fetch AssemblyAI token (HTTP {response.status_code}): {response.text}"
            )
        token = response.json().get("token")
        if not token:
            raise TranscriptionProviderError("Invalid token response from proxy.")
        return token


class _AssemblyAIStreamingTranscriptionSession(StreamingTranscriptionSession):
    """Active streaming session. The websocket lives on the shared asyncio
    loop; every protocol-state mutation also happens there, so no locking is
    needed — same single-threaded discipline as the Swift stateQueue."""

    def __init__(
        self,
        temporary_token: str,
        loop_thread: "_WebsocketLoopThread",
        keyterms: list[str],
        on_transcript_update: Callable[[str], None],
        on_final_transcript_ready: Callable[[str], None],
        on_error: Callable[[Exception], None],
    ):
        self._temporary_token = temporary_token
        self._loop_thread = loop_thread
        self._keyterms = keyterms
        self._on_transcript_update = on_transcript_update
        self._on_final_transcript_ready = on_final_transcript_ready
        self._on_error = on_error

        # Only mutated on the loop thread
        self._websocket = None
        self._receive_task: Optional[asyncio.Task] = None
        self._stored_turn_transcripts_by_order: dict[int, dict] = {}
        self._active_turn_order: Optional[int] = None
        self._active_turn_transcript_text = ""
        self._latest_transcript_text = ""
        self._has_delivered_final_transcript = False
        self._is_awaiting_explicit_final_transcript = False
        self._explicit_final_deadline_handle: Optional[asyncio.TimerHandle] = None
        self._session_failed_error: Optional[Exception] = None

    # -- lifecycle (callable from any thread) --------------------------------

    def open(self) -> None:
        if websockets is None:
            raise TranscriptionProviderError(
                "The `websockets` package is not installed — cannot stream from AssemblyAI."
            )
        websocket_url = self._make_websocket_url()
        _run_coroutine_on_shared_loop(
            self._connect_and_start_receiving(websocket_url), self._loop_thread, timeout=15.0
        )

    async def _connect_and_start_receiving(self, websocket_url: str):
        # header authorization is not needed with the temporary token query param
        self._websocket = await websockets.connect(websocket_url)
        self._receive_task = asyncio.get_running_loop().create_task(
            self._receive_coroutine()
        )

    def _make_websocket_url(self) -> str:
        """Builds the wss URL with the same query parameters as Swift."""
        query = {
            "sample_rate": "16000",
            "encoding": "pcm_s16le",
            "format_turns": "true",
            "speech_model": "u3-rt-pro",
        }
        normalized_keyterms = [k.strip() for k in self._keyterms if k.strip()]
        if normalized_keyterms:
            query["keyterms_prompt"] = json.dumps(normalized_keyterms)
        if self._temporary_token:
            query["token"] = self._temporary_token
        encoded_query = "&".join(
            f"{name}={_query_escape(value)}" for name, value in query.items()
        )
        return f"{self.websocket_base_url}?{encoded_query}"

    def append_audio_buffer(self, pcm16_bytes: bytes) -> None:
        if self._websocket is None:
            return
        self._loop_thread.submit_coroutine(self._websocket.send(pcm16_bytes))

    def request_final_transcript(self) -> None:
        """Called on key-up. Mirrors the Swift flow: set the awaiting flag,
        schedule the 1.4 s grace deadline, then send ForceEndpoint."""
        self._loop_thread.submit(self._prepare_explicit_final)

    def cancel(self) -> None:
        """Terminates the session without delivering a transcript."""
        self._loop_thread.submit(self._close_after_terminate)

    # -- loop-thread-only methods --------------------------------------------

    def _prepare_explicit_final(self):
        if self._has_delivered_final_transcript or self._session_failed_error:
            return
        self._is_awaiting_explicit_final_transcript = True
        self._schedule_explicit_final_deadline()
        self._send_json_now({"type": "ForceEndpoint"})

    def _schedule_explicit_final_deadline(self):
        if self._explicit_final_deadline_handle is not None:
            self._explicit_final_deadline_handle.cancel()
        self._explicit_final_deadline_handle = asyncio.get_running_loop().call_later(
            self.explicit_final_transcript_grace_period_seconds,
            lambda: self._deliver_final_transcript_if_needed(
                self._best_available_transcript_text()
            ),
        )

    def _cancel_explicit_final_deadline(self):
        if self._explicit_final_deadline_handle is not None:
            self._explicit_final_deadline_handle.cancel()
            self._explicit_final_deadline_handle = None

    def _close_after_terminate(self):
        self._cancel_explicit_final_deadline()
        if self._websocket is not None:
            self._send_json_now({"type": "Terminate"})
            closing_coroutine = self._websocket.close()
            websocket = self._websocket
            self._websocket = None
            self._loop_thread.submit_coroutine_and_forget(closing_coroutine, websocket)

    async def _receive_coroutine(self):
        """Runs on the shared loop until the socket closes. Message handling
        is a direct port of handleIncomingTextMessage."""
        try:
            async for raw_message in self._websocket:
                text = raw_message.decode("utf-8") if isinstance(raw_message, bytes) else raw_message
                self._handle_incoming_text_message(text)
        except Exception as websocket_error:
            # Normal closes ("KeepAlive timeout", code 1000) are not failures;
            # a failed receive only matters if the session is still active.
            if self._websocket is not None:
                self._fail_session(websocket_error)

    def _handle_incoming_text_message(self, text: str):
        try:
            envelope = json.loads(text)
        except json.JSONDecodeError:
            return
        message_type = str(envelope.get("type", "")).lower()

        if message_type == "begin":
            pass  # connection confirmed — Swift resolves a ready continuation here
        elif message_type == "turn":
            self._handle_turn_message(envelope)
        elif message_type == "termination":
            if (
                self._is_awaiting_explicit_final_transcript
                and not self._has_delivered_final_transcript
            ):
                self._deliver_final_transcript_if_needed(
                    self._best_available_transcript_text()
                )
        elif message_type == "error":
            message_text = (
                envelope.get("error") or envelope.get("message")
                or "AssemblyAI returned an error."
            )
            self._fail_session(TranscriptionProviderError(message_text))

    def _handle_turn_message(self, turn_message: dict):
        """Ports handleTurnMessage: committed turns are stored by turn_order,
        in-flight turns compose as text, formatted turns win over unformatted
        ones, and the full transcript is reported after every event."""
        transcript_text = (turn_message.get("transcript") or "").strip()
        end_of_turn = turn_message.get("end_of_turn") is True
        turn_is_formatted = turn_message.get("turn_is_formatted") is True
        turn_order = turn_message.get("turn_order")
        if turn_order is None:
            turn_order = (
                self._active_turn_order
                if self._active_turn_order is not None
                else (max(self._stored_turn_transcripts_by_order.keys(), default=-1) + 1)
            )

        if end_of_turn or turn_is_formatted:
            self._active_turn_order = None
            self._active_turn_transcript_text = ""
            self._store_turn_transcript(
                transcript_text, turn_order=turn_order, is_formatted=turn_is_formatted
            )
        else:
            self._active_turn_order = turn_order
            self._active_turn_transcript_text = transcript_text

        full_transcript_text = self._compose_full_transcript()
        self._latest_transcript_text = full_transcript_text

        if full_transcript_text:
            self._on_transcript_update(full_transcript_text)

        if not self._is_awaiting_explicit_final_transcript:
            return

        if end_of_turn or turn_is_formatted:
            self._cancel_explicit_final_deadline()
            self._deliver_final_transcript_if_needed(self._best_available_transcript_text())

    def _store_turn_transcript(self, transcript_text: str, turn_order: int, is_formatted: bool):
        if not transcript_text:
            return
        existing = self._stored_turn_transcripts_by_order.get(turn_order)
        if existing and existing["is_formatted"] and not is_formatted:
            return
        self._stored_turn_transcripts_by_order[turn_order] = {
            "transcript_text": transcript_text,
            "is_formatted": is_formatted,
        }

    def _compose_full_transcript(self) -> str:
        committed_segments = [
            stored_turn["transcript_text"]
            for _turn_order, stored_turn in sorted(
                self._stored_turn_transcripts_by_order.items(), key=lambda item: item[0]
            )
            if stored_turn["transcript_text"]
        ]
        segments = committed_segments
        active_text = (self._active_turn_transcript_text or "").strip()
        if active_text:
            segments = segments + [active_text]
        return " ".join(segments)

    def _best_available_transcript_text(self) -> str:
        composed = self._compose_full_transcript().strip()
        if composed:
            return composed
        return (self._latest_transcript_text or "").strip()

    def _deliver_final_transcript_if_needed(self, transcript_text: str):
        if self._has_delivered_final_transcript:
            return
        self._has_delivered_final_transcript = True
        self._cancel_explicit_final_deadline()
        self._on_final_transcript_ready(transcript_text)
        if self._websocket is not None:
            self._send_json_now({"type": "Terminate"})

    def _send_json_now(self, payload: dict):
        """Send synchronously on the loop thread (we are already on it)."""
        try:
            send_task = self._loop_thread.ensure_task_now(
                self._websocket.send(json.dumps(payload))
            )
            # Sending Fire-and-forget: caller paths run inside the loop, so we
            # can schedule the coroutine without awaiting it.
            _ = send_task
        except Exception as send_error:
            self._fail_session(send_error)

    def _fail_session(self, error: Exception):
        """Ports failSession: if we were awaiting a final transcript and we
        already have words, deliver the partial text instead of erroring."""
        if self._session_failed_error is not None:
            return
        self._session_failed_error = error
        self._cancel_explicit_final_deadline()
        latest_transcript_text = self._best_available_transcript_text()
        if (
            self._is_awaiting_explicit_final_transcript
            and not self._has_delivered_final_transcript
            and latest_transcript_text
        ):
            self._deliver_final_transcript_if_needed(latest_transcript_text)
            return
        self._on_error(error)


class OpenAIAudioTranscriptionProvider(TranscriptionProvider):
    """Upload-based transcription provider. Buffers push-to-talk audio
    locally, uploads as WAV on release, returns the finalized transcript.
    Requires OPENAI_API_KEY in the environment (the macOS app reads it from
    the app bundle; on Windows the environment is the equivalent)."""

    display_name = "OpenAI"

    def start_streaming_session(
        self,
        keyterms: list[str],
        on_transcript_update: Callable[[str], None],
        on_final_transcript_ready: Callable[[str], None],
        on_error: Callable[[Exception], None],
    ) -> StreamingTranscriptionSession:
        return _OpenAIUploadBufferingSession(
            on_final_transcript_ready=on_final_transcript_ready,
            on_error=on_error,
        )


class _OpenAIUploadBufferingSession(StreamingTranscriptionSession):
    """Non-streaming fallback: accumulates PCM16 audio and uploads on release."""

    def __init__(
        self,
        on_final_transcript_ready: Callable[[str], None],
        on_error: Callable[[Exception], None],
    ):
        self._audio_accumulator = bytearray()
        self._on_final_transcript_ready = on_final_transcript_ready
        self._on_error = on_error
        self._has_finalized = False

    def append_audio_buffer(self, pcm16_bytes: bytes) -> None:
        if self._has_finalized:
            return
        self._audio_accumulator.extend(pcm16_bytes)

    def request_final_transcript(self) -> None:
        from threading import Thread

        # Uploading blocks for the network round-trip; keep it off the key-up path.
        Thread(target=self._upload_final_audio, daemon=True).start()

    def cancel(self) -> None:
        self._has_finalized = True

    def _upload_final_audio(self):
        from .audio_conversion import WAVFileBuilder

        try:
            import httpx

            api_key = _openai_api_key_from_environment()
            wav_payload = WAVFileBuilder.build_wav_data(
                bytes(self._audio_accumulator), sample_rate=16_000
            )
            response = httpx.post(
                "https://api.openai.com/v1/audio/transcriptions",
                headers={"Authorization": f"Bearer {api_key}"},
                files={"file": ("dictation.wav", wav_payload, "audio/wav")},
                data={"model": "gpt-4o-mini-transcribe"},
                timeout=60.0,
            )
            if not (200 <= response.status_code < 300):
                raise TranscriptionProviderError(
                    f"OpenAI transcription error ({response.status_code}): {response.text}"
                )
            transcript = response.json().get("text", "")
            if not self._has_finalized:
                self._on_final_transcript_ready(transcript)
        except Exception as upload_error:
            self._on_error(upload_error)


def _openai_api_key_from_environment() -> str:
    import os

    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        raise TranscriptionProviderError(
            "OPENAI_API_KEY is not set in the environment — cannot use the OpenAI provider."
        )
    return api_key


def resolve_transcription_provider(
    provider_choice: Optional[str], proxy_base_url: str
) -> TranscriptionProvider:
    """Provider factory, mirroring BuddyTranscriptionProvider's resolution.
    The Info.plist `VoiceTranscriptionProvider` key becomes the
    VOICE_TRANSCRIPTION_PROVIDER environment variable (or the config file)."""
    normalized_choice = (provider_choice or "assemblyai").lower()
    if normalized_choice == "assemblyai":
        return AssemblyAIStreamingTranscriptionProvider(proxy_base_url)
    if normalized_choice == "openai":
        return OpenAIAudioTranscriptionProvider(proxy_base_url)
    raise TranscriptionProviderError(f"Unknown transcription provider: {provider_choice}")


class _WebsocketLoopThread(threading.Thread):
    """Runs one asyncio loop for the whole app's AssemblyAI sessions."""

    def __init__(self, start_it: bool = False):
        super().__init__(daemon=True)
        self._event_loop = asyncio.new_event_loop()
        self._started = threading.Event()
        if start_it:
            self.start()
            self._started.wait(timeout=2.0)

    def run(self):
        asyncio.set_event_loop(self._event_loop)
        self._started.set()
        self._event_loop.run_forever()

    def submit(self, callable_):
        """Runs callable_ once on the loop thread."""
        self._started.wait(timeout=2.0)
        self._event_loop.call_soon_threadsafe(callable_)

    def submit_coroutine(self, coroutine) -> Future:
        """Runs coroutine on the loop thread, returning a Future of the result."""
        self._started.wait(timeout=2.0)
        return asyncio.run_coroutine_threadsafe(coroutine, self._event_loop)

    def submit_coroutine_and_forget(self, coroutine, websocket):
        """Schedules a coroutine whose exceptions should not crash anything
        (e.g. closing an already-closed websocket). Used for teardown paths."""

        async def _swallow():
            try:
                await coroutine
            except Exception as close_error:
                _ = websocket
                print(f"[AssemblyAI] teardown error (ignored): {close_error}")

        self.submit_coroutine(_swallow())

    def ensure_task_now(self, coroutine) -> asyncio.Task:
        return self._event_loop.create_task(coroutine)


def _query_escape(value: str) -> str:
    from urllib.parse import quote

    return quote(value, safe="")


__all__ = [
    "TranscriptionProvider",
    "StreamingTranscriptionSession",
    "TranscriptionProviderError",
    "AssemblyAIStreamingTranscriptionProvider",
    "OpenAIAudioTranscriptionProvider",
    "resolve_transcription_provider",
]
