"""Push-to-talk voice pipeline — port of BuddyDictationManager.swift and
GlobalPushToTalkShortcutMonitor.swift.

Pieces:
- GlobalPushToTalkShortcutMonitor: a background pynput keyboard listener
  standing in for the Swift listen-only CGEvent tap. Detects press/release
  transitions of the push-to-talk combo (ctrl+alt) system-wide.
- BuddyDictationManager: mic capture via sounddevice (AVAudioEngine's
  counterpart), PCM16 conversion, and a transcription provider session;
  emits Qt signals for transcript updates, audio power, and finalization.
"""

from __future__ import annotations

from typing import Optional

from PySide6.QtCore import QObject, Signal

from .transcription import (
    StreamingTranscriptionSession,
    TranscriptionProvider,
    TranscriptionProviderError,
)


class GlobalPushToTalkShortcutMonitor(QObject):
    """Listens system-wide for the push-to-talk combo and emits edge
    transitions (pressed/released) — same contract as the CGEvent tap."""

    shortcutTransitionedToActive = Signal()
    shortcutTransitionedToInactive = Signal()

    def __init__(self, hold_keys=("ctrl", "alt"), parent: Optional[QObject] = None):
        super().__init__(parent)
        self._hold_keys = set(hold_keys)
        self._currently_held_keys: set[str] = set()
        self._push_to_talk_is_active = False
        self._keyboard_listener = None

    def start_monitoring(self):
        from pynput import keyboard as pynput_keyboard

        key_aliases = {
            "ctrl": {pynput_keyboard.Key.ctrl, pynput_keyboard.Key.ctrl_l, pynput_keyboard.Key.ctrl_r},
            "alt": {pynput_keyboard.Key.alt, pynput_keyboard.Key.alt_l, pynput_keyboard.Key.alt_r},
        }
        reversed_aliases = {
            key: name for name, keys in key_aliases.items() for key in keys
        }

        def on_key_press(key):
            key_name = reversed_aliases.get(key)
            if key_name is None:
                return
            self._currently_held_keys.add(key_name)
            self._recheck_combo_state(active=True)

        def on_key_release(key):
            key_name = reversed_aliases.get(key)
            if key_name is None:
                return
            self._currently_held_keys.discard(key_name)
            self._recheck_combo_state(active=False)

        self._keyboard_listener = pynput_keyboard.Listener(
            on_press=on_key_press, on_release=on_key_release
        )
        self._keyboard_listener.start()

    def _recheck_combo_state(self, active: bool):
        """Fires transitions only when the edge actually changes — the
        equivalent of the Swift dispatching on press/release transitions."""
        combo_now_active = self._hold_keys.issubset(self._currently_held_keys)
        if active and combo_now_active and not self._push_to_talk_is_active:
            self._push_to_talk_is_active = True
            self.shortcutTransitionedToActive.emit()
        elif not active and not combo_now_active and self._push_to_talk_is_active:
            self._push_to_talk_is_active = False
            self.shortcutTransitionedToInactive.emit()

    def is_combo_held(self) -> bool:
        return self._push_to_talk_is_active


class BuddyDictationManager(QObject):
    """Owns one dictation session: mic stream -> PCM16 -> provider session."""

    transcriptUpdated = Signal(str)
    finalTranscriptReady = Signal(str)
    dictationEnded = Signal()
    dictationFailed = Signal(str)
    audioPowerLevelUpdated = Signal(float)

    def __init__(
        self,
        transcription_provider: TranscriptionProvider,
        parent: Optional[QObject] = None,
    ):
        super().__init__(parent)
        self.transcription_provider = transcription_provider
        self.active_session: Optional[StreamingTranscriptionSession] = None
        self.microphone_stream = None
        self.pcm16_converter = None

    @property
    def is_dictating(self) -> bool:
        return self.active_session is not None

    def start_keyboard_dictation(self, keyterms: Optional[list[str]] = None):
        """Starts push-to-talk capture. Callbacks emitted as Qt signals so
        CompanionManager stays on the main thread, like the Swift design."""
        if self.is_dictating:
            return

        session_error_capture: list[Exception] = []

        def on_transcript_update(transcript_text: str):
            self.transcriptUpdated.emit(transcript_text)

        def on_final_transcript_ready(final_transcript: str):
            self.active_session = None
            self._stop_microphone_stream()
            self.finalTranscriptReady.emit(final_transcript)

        def on_error(session_error: Exception):
            session_error_capture.append(session_error)
            self.active_session = None
            self._stop_microphone_stream()
            self.dictationFailed.emit(str(session_error))

        # Provider sessions are created up front so mic audio flows into the
        # websocket from the first callback (Swift does the same in
        # startDictationTask).
        self.active_session = self.transcription_provider.start_streaming_session(
            keyterms=keyterms or [],
            on_transcript_update=on_transcript_update,
            on_final_transcript_ready=on_final_transcript_ready,
            on_error=on_error,
        )

        self.pcm16_converter = _build_converter(
            on_audio_level=self.audioPowerLevelUpdated.emit
        )
        self._start_microphone_stream(session_error_capture)

    def _start_microphone_stream(self, session_error_capture: list[Exception]):
        import sounddevice

        def mic_callback(indata, frames, time_info, status):
            if status:
                # PortAudio overflows are usually recoverable; log and continue
                print(f"[dictation] mic status: {status}")
            session = self.active_session
            if session is None:
                return
            pcm16_bytes = self.pcm16_converter.convert_to_pcm16_bytes(indata)
            if pcm16_bytes:
                session.append_audio_buffer(pcm16_bytes)

        self.microphone_stream = sounddevice.InputStream(
            samplerate=48_000,
            channels=1,
            dtype="float32",
            blocksize=0,  # let PortAudio choose a low-latency block size
            callback=mic_callback,
        )
        self.microphone_stream.start()

    def _stop_microphone_stream(self):
        if self.microphone_stream is not None:
            try:
                self.microphone_stream.stop()
            finally:
                self.microphone_stream.close()
                self.microphone_stream = None

    def end_dictation(self):
        """Key-up: asks the provider for the final transcript (which stops the
        mic stream when it arrives)."""
        if self.active_session is None:
            return
        self.active_session.request_final_transcript()

    def cancel_dictation(self):
        if self.active_session is not None:
            self.active_session.cancel()
            self.active_session = None
        self._stop_microphone_stream()
        self.dictationEnded.emit()


def _build_converter(on_audio_level) -> "object":
    """PCM16AudioConverter bound to the mic rate; the rate is snapped once the
    first block arrives, mirroring the AVAudioConverter's lazy format setup."""
    from .audio_conversion import PCM16AudioConverter

    converter = PCM16AudioConverter(
        target_sample_rate=16_000, on_audio_level=on_audio_level
    )

    original_convert = converter.convert_to_pcm16_bytes

    def rate_aware_convert(float32_buffer: bytes):
        # sounddevice.InputStream's actual rate is passed in by the caller
        # through `_set_source_rate`; until then assume 48 kHz.
        if converter._source_sample_rate is None:
            converter.session_source_format_changed(48_000)
        return original_convert(float32_buffer)

    converter.convert_to_pcm16_bytes = rate_aware_convert
    return converter


class TranscriptionChoiceResolver:
    """Swaps providers at runtime when the user picks one in the panel, and
    forwards provider failures to the panel as readable text."""

    def __init__(self, proxy_base_url: str, provider_choice: Optional[str] = None):
        from .transcription import resolve_transcription_provider

        self.proxy_base_url = proxy_base_url
        self.provider_choice = provider_choice

    @property
    def provider(self) -> TranscriptionProvider:
        from .transcription import resolve_transcription_provider

        try:
            return resolve_transcription_provider(self.provider_choice, self.proxy_base_url)
        except TranscriptionProviderError:
            # Unknown choice falls back to the default streaming provider
            return resolve_transcription_provider("assemblyai", self.proxy_base_url)
