"""Central state machine for the companion voice mode — port of
CompanionManager.swift.

Coordinates: tray/panel (MenuBarPanelManager push-to-talk transitions),
global push-to-talk monitor, dictation, screen capture, Claude API,
ElevenLabs TTS, and the overlay. Voice state (idle/listening/processing/
responding) is published via signals exactly like the @Published state in
Swift; all Qt work happens on the main thread, and worker threads marshal
back through signals.
"""

from __future__ import annotations

from typing import Optional

from PySide6.QtCore import QObject, Signal

from .analytics import ClickyAnalytics
from .companion_system_prompt import COMPANION_VOICE_RESPONSE_SYSTEM_PROMPT
from .config import CompanionSettings


class CompanionVoiceState:
    """Values match the Swift enum for easy cross-referencing."""

    IDLE = "idle"
    LISTENING = "listening"
    PROCESSING = "processing"
    RESPONDING = "responding"


class CompanionManager(QObject):
    voiceStateChanged = Signal(str)
    lastTranscriptChanged = Signal(str)
    # Overlay commands (main-thread entry points)
    overlayShowRequested = Signal(str)  # live transcript while listening / response text
    overlayShowSpinnerRequested = Signal()
    overlayResponseTextChanged = Signal(str)
    overlayAudioPowerChanged = Signal(float)
    overlayDismissRequested = Signal()
    # Asking the overlay to fly to a global logical point (element pointing)
    pointingTargetRequested = Signal(float, float)
    # Worker thread -> main thread screen capture round-trip: (holder, completion_event)
    captureRequested = Signal(object, object)
    # Chat backend changed: (model_choices, selected_model) for the panel combo
    modelChoicesChanged = Signal(list, str)

    def __init__(
        self,
        settings: CompanionSettings,
        panel_manager,
        dictation_manager,
        push_to_talk_monitor,
        parent: Optional[QObject] = None,
    ):
        super().__init__(parent)
        self.settings = settings
        self.panel_manager = panel_manager
        self.dictation_manager = dictation_manager
        self.push_to_talk_monitor = push_to_talk_monitor
        self.analytics = ClickyAnalytics()

        self._voice_state: str = CompanionVoiceState.IDLE
        self._last_transcript: Optional[str] = None
        self._conversation_history: list[tuple[str, str]] = []
        self._response_worker_cancelled = False
        self._microphone_available = True

        from .chat import resolve_chat_client

        # Claude (Worker proxy) by default; OpenAI direct when the panel or
        # settings say so. resolve_chat_client falls back to Claude if the
        # OpenAI key is missing.
        self.chat_client = resolve_chat_client(settings)

        from .tts import ElevenLabsTTSClient

        self.eleven_labs_tts_client = ElevenLabsTTSClient(
            proxy_url=f"{settings.proxy_base_url.rstrip('/')}/tts"
        )
        # TTS lifecycle callbacks arrive from the media player on the main thread
        self.eleven_labs_tts_client.playbackStarted.connect(
            self._on_tts_playback_started
        )
        self.eleven_labs_tts_client.playbackFinished.connect(
            self._on_tts_playback_finished
        )

        self._wire_signals()

    # -- wiring -------------------------------------------------------------

    def _wire_signals(self):
        # Push-to-talk edges drive the pipeline
        self.push_to_talk_monitor.shortcutTransitionedToActive.connect(
            self.on_push_to_talk_started
        )
        self.push_to_talk_monitor.shortcutTransitionedToInactive.connect(
            self.on_push_to_talk_stopped
        )

        # Panel "hold to talk" button (same start path as the keyboard combo)
        self.panel_manager.holdToTalkPressed.connect(self.on_push_to_talk_started)
        self.panel_manager.holdToTalkReleased.connect(self.on_push_to_talk_stopped)

        # Dictation results
        self.dictation_manager.transcriptUpdated.connect(self._on_transcript_update)
        self.dictation_manager.finalTranscriptReady.connect(self._on_final_transcript)
        self.dictation_manager.dictationFailed.connect(self._on_dictation_failed)
        self.dictation_manager.audioPowerLevelUpdated.connect(
            self.overlayAudioPowerChanged
        )

        # Panel options
        self.panel_manager.modelSelected.connect(self.set_selected_model)
        self.panel_manager.transcriptionProviderSelected.connect(
            self._on_transcription_provider_selected
        )
        self.panel_manager.clickyCursorPreferenceChanged.connect(
            self._on_clicky_cursor_preference_changed
        )
        self.panel_manager.chatProviderSelected.connect(self._on_chat_backend_selected)
        # Model list refreshes flow straight into the panel's picker
        self.modelChoicesChanged.connect(
            self.panel_manager.companion_panel.set_model_choices
        )

    # -- state ---------------------------------------------------------------

    @property
    def voice_state(self) -> str:
        return self._voice_state

    def _set_voice_state(self, new_state: str):
        if new_state == self._voice_state:
            return
        self._voice_state = new_state
        self.voiceStateChanged.emit(new_state)
        status_text = _STATUS_TEXT_FOR_STATE.get(new_state, new_state)
        if new_state == CompanionVoiceState.IDLE and not self._microphone_available:
            status_text = "no microphone found — check Windows sound settings"
        self.panel_manager.set_companion_status(status_text)

    # -- device checks ---------------------------------------------------------

    def check_microphone_availability(self):
        """Probes PortAudio for any input device so the panel can say so up
        front instead of failing on the first push-to-talk. Called once from
        main() during startup."""
        try:
            import sounddevice

            microphone_found = any(
                device.get("max_input_channels", 0) > 0
                for device in sounddevice.query_devices()
            )
        except Exception as audio_probe_error:
            print(f"[startup] audio probe failed: {audio_probe_error}")
            microphone_found = False

        self._microphone_available = microphone_found
        if not microphone_found:
            self.panel_manager.set_companion_status(
                "no microphone found — check Windows sound settings"
            )
        print(f"🎙️ Microphone available: {microphone_found}")

    # -- push-to-talk edges ---------------------------------------------------

    def on_push_to_talk_started(self):
        """Start dictation. A second push interrupts an in-flight response
        (Swift cancels currentResponseTask + stops TTS here)."""
        self._response_worker_cancelled = True
        self.eleven_labs_tts_client.stop_playback()

        if self.dictation_manager.is_dictating:
            return

        self._set_voice_state(CompanionVoiceState.LISTENING)
        self.overlayShowRequested.emit("")  # show overlay with empty transcript
        self.analytics.push_to_talk_pressed()
        try:
            self.dictation_manager.start_keyboard_dictation()
        except Exception as dictation_start_error:
            print(f"⚠️ Dictation start failed: {dictation_start_error}")
            self._on_dictation_failed(str(dictation_start_error))

    def on_push_to_talk_stopped(self):
        if self.dictation_manager.is_dictating:
            self.dictation_manager.end_dictation()

    def _on_transcript_update(self, transcript_text: str):
        self._last_transcript = transcript_text
        self.lastTranscriptChanged.emit(transcript_text)
        self.overlayShowRequested.emit(transcript_text)

    def _on_final_transcript(self, final_transcript: str):
        self._set_voice_state(CompanionVoiceState.PROCESSING)
        self.overlayShowSpinnerRequested.emit()
        if not final_transcript.strip():
            self._set_voice_state(CompanionVoiceState.IDLE)
            return
        self._start_response_pipeline(final_transcript)

    def _on_dictation_failed(self, error_text: str):
        print(f"⚠️ Transcription error: {error_text}")
        self.analytics.track_transcription_error(error_text)
        self._set_voice_state(CompanionVoiceState.IDLE)
        self.overlayDismissRequested.emit()
        self.panel_manager.set_companion_status(f"transcription error — {error_text[:80]}")

    # -- AI response pipeline ---------------------------------------------------

    def _start_response_pipeline(self, transcript: str):
        """Captures screenshots, calls Claude streaming, then speaks — all on
        a worker thread, mirroring the Swift Task in
        sendTranscriptToClaudeWithScreenshot."""
        from threading import Thread

        self._response_worker_cancelled = False

        def run_pipeline():
            try:
                pipeline_result = _ResponsePipelineResult()
                self._capture_and_query_claude(
                    transcript, pipeline_result, is_cancelled_fn=lambda: self._response_worker_cancelled
                )
                if self._response_worker_cancelled:
                    return
                self._handle_ai_response(transcript, pipeline_result)
            except Exception as pipeline_error:
                if self._response_worker_cancelled:
                    return
                print(f"⚠️ Companion response error: {pipeline_error}")
                self.analytics.track_response_error(str(pipeline_error))
                self.overlayResponseTextChanged.emit(f"error — {str(pipeline_error)[:120]}")
                self._set_voice_state(CompanionVoiceState.IDLE)

        pipeline_thread = Thread(target=run_pipeline, daemon=True, name="companion-response")
        pipeline_thread.start()

    def _request_capture_from_main_thread(self):
        """Round-trip: the overlays must hide on the GUI thread before mss
        grabs the desktop, and Qt widget calls are only safe on the main
        thread. So the response worker emits `captureRequested`, the main
        thread's receiver hides/captures/reshows, and this call blocks until
        the completion event resolves (Swift got this for free via
        ScreenCaptureKit's per-window exclusion + actor re-entrancy)."""
        from threading import Event

        capture_holder = {"captures": None, "error": None}
        completion_event = Event()
        self.captureRequested.emit(capture_holder, completion_event)
        if not completion_event.wait(timeout=20.0):
            raise RuntimeError("Screen capture timed out waiting for the main thread")
        if capture_holder["error"] is not None:
            raise capture_holder["error"]
        return capture_holder["captures"]

    def _capture_and_query_claude(
        self, transcript: str, pipeline_result: "_ResponsePipelineResult", is_cancelled_fn
    ):
        """Worker-thread body: screenshots -> labeled images -> streamed Claude call."""
        screen_captures = self._request_capture_from_main_thread()

        if is_cancelled_fn():
            return

        # Build image labels with actual screenshot pixel dimensions so
        # Claude's coordinate space matches the image it sees.
        labeled_images = []
        for screen_capture in screen_captures:
            dimension_info = (
                f" (image dimensions: {screen_capture.screenshot_width_in_pixels}"
                f"x{screen_capture.screenshot_height_in_pixels} pixels)"
            )
            labeled_images.append(
                (screen_capture.image_data, screen_capture.label + dimension_info)
            )

        payload_mb = sum(len(image_data) for image_data, _label in labeled_images) / 1_048_576.0
        print(
            f"🌐 Claude streaming request: {payload_mb:.1f}MB, {len(labeled_images)} image(s)"
        )

        full_response_text, _duration = self.chat_client.analyze_image_streaming(
            images=labeled_images,
            system_prompt=COMPANION_VOICE_RESPONSE_SYSTEM_PROMPT,
            conversation_history=list(self._conversation_history),
            user_prompt=transcript,
            on_text_chunk=lambda chunk: None,
            # No streaming bubble — the Swift version also keeps the spinner
            is_cancelled_fn=lambda: self._response_worker_cancelled,
        )
        pipeline_result.full_response_text = full_response_text
        pipeline_result.screen_captures = screen_captures

    def _handle_ai_response(self, transcript: str, pipeline_result: "_ResponsePipelineResult"):
        from .element_pointing import parse_pointing_coordinates

        parse_result = parse_pointing_coordinates(pipeline_result.full_response_text)
        spoken_text = parse_result.spoken_text

        # Element pointing: pick the capture matching Claude's screen number,
        # falling back to the cursor screen (identical to Swift).
        target_screen_capture = None
        if parse_result.screen_number is not None:
            screen_index = parse_result.screen_number - 1
            if 0 <= screen_index < len(pipeline_result.screen_captures):
                target_screen_capture = pipeline_result.screen_captures[screen_index]
        if target_screen_capture is None:
            target_screen_capture = next(
                (
                    capture
                    for capture in pipeline_result.screen_captures
                    if capture.is_cursor_screen
                ),
                None,
            )

        global_point = self._map_parsed_coordinate_to_global_point(
            parse_result, target_screen_capture
        )
        if global_point is not None:
            print(
                f"🎯 Element pointing: ({parse_result.coordinate[0]}, "
                f"{parse_result.coordinate[1]}) → "
                f"\"{parse_result.element_label or 'element'}\" → global {global_point}"
            )
            self.analytics.track_element_pointed(parse_result.element_label)
            self.overlayResponseTextChanged.emit(spoken_text)
            self._emit_pointing_to_overlay(global_point)
        else:
            self.overlayResponseTextChanged.emit(spoken_text)

        # Save this exchange to history (point tag stripped so it doesn't
        # confuse future context), keeping the last 10 exchanges.
        self._conversation_history.append((transcript, spoken_text))
        if len(self._conversation_history) > 10:
            self._conversation_history = self._conversation_history[-10:]
        print(f"🧠 Conversation history: {len(self._conversation_history)} exchanges")

        self.analytics.track_ai_response_received(spoken_text)

        if not spoken_text.strip():
            self._set_voice_state(CompanionVoiceState.IDLE)
            return

        # TTS fetch happens on this worker thread; playback + callbacks are main-
        # thread (QMediaPlayer). While waiting, the overlay keeps the spinner
        # — _set_voice_state(RESPONDING) fires on playbackStarted.
        try:
            self.eleven_labs_tts_client.speak_text(spoken_text)
            self._set_voice_state(CompanionVoiceState.RESPONDING)
        except Exception as tts_error:
            print(f"⚠️ ElevenLabs TTS error: {tts_error}")
            self.analytics.track_tts_error(str(tts_error))
            self._speak_credits_error_fallback()

    def _map_parsed_coordinate_to_global_point(self, parse_result, target_screen_capture):
        """Screenshot pixels -> global logical Qt point. Returns None if there
        is nothing to point at. Centers the buddy on the element with a small
        offset so the tip lands near the target like the mac version."""
        from .element_pointing import (
            clamp_point_to_screenshot,
            map_screenshot_point_to_global_logical_point,
        )

        if parse_result.coordinate is None or target_screen_capture is None:
            return None

        clamped_point = clamp_point_to_screenshot(
            parse_result.coordinate,
            (
                target_screen_capture.screenshot_width_in_pixels,
                target_screen_capture.screenshot_height_in_pixels,
            ),
        )
        logical_point = map_screenshot_point_to_global_logical_point(
            screenshot_point=clamped_point,
            screenshot_size_px=(
                target_screen_capture.screenshot_width_in_pixels,
                target_screen_capture.screenshot_height_in_pixels,
            ),
            display_size_physical_px=(
                int(
                    target_screen_capture.display_width_in_logical_points
                    * target_screen_capture.device_pixel_ratio
                ),
                int(
                    target_screen_capture.display_height_in_logical_points
                    * target_screen_capture.device_pixel_ratio
                ),
            ),
            display_device_pixel_ratio=target_screen_capture.device_pixel_ratio,
            display_frame_logical=(
                target_screen_capture.display_frame[0],
                target_screen_capture.display_frame[1],
            ),
        )
        return logical_point

    def _emit_pointing_to_overlay(self, global_point: tuple[float, float]):
        """CompanionManager stays transport-agnostic; main.py owns the real
        overlay widgets and finishes the flight animation."""
        self.pointingTargetRequested.emit(global_point[0], global_point[1])

    def _speak_credits_error_fallback(self):
        """Speaks the hardcoded error using Windows SAPI when ElevenLabs is
        down — the NSSpeechSynthesizer equivalent."""
        from threading import Thread

        def speak_fallback():
            try:
                import win32com.client  # pywin32

                sapi_speaker = win32com.client.Dispatch("SAPI.SpVoice")
                sapi_speaker.Speak(
                    "I'm all out of credits. Please DM Farza and tell him to bring me back to life."
                )
            except Exception as sapi_error:
                print(f"[fallback tts] SAPI unavailable: {sapi_error}")

        Thread(target=speak_fallback, daemon=True).start()
        self._set_voice_state(CompanionVoiceState.RESPONDING)

    # -- TTS callbacks -----------------------------------------------------------

    def _on_tts_playback_started(self):
        self._set_voice_state(CompanionVoiceState.RESPONDING)

    def _on_tts_playback_finished(self):
        if self.dictation_manager.is_dictating:
            return
        self._set_voice_state(CompanionVoiceState.IDLE)
        # Transient cursor mode: after the interaction completes (response
        # spoken, pointing arc done), fade out after 1 second of inactivity —
        # the scheduleTransientHideIfNeeded behavior. A new push cancels it
        # naturally: _ensure re-show happens on the next pushToTalk start.
        if not self.settings.is_clicky_cursor_enabled:
            self._schedule_transient_hide()

    def _schedule_transient_hide(self):
        from PySide6.QtCore import QTimer

        QTimer.singleShot(1_000, self._maybe_dismiss_transient_overlay)

    def _maybe_dismiss_transient_overlay(self):
        if not self.dictation_manager.is_dictating and self._voice_state == CompanionVoiceState.IDLE:
            self.overlayDismissRequested.emit()

    # -- panel options ------------------------------------------------------------

    def set_selected_model(self, model: str):
        self.settings.selected_model = model
        self.settings.save()
        self.chat_client.model = model
        print(f"🧠 Model: {model}")

    def _on_chat_backend_selected(self, backend: str):
        """Panel asked for the other chat backend. Model lists differ per
        backend, so an invalid model resets to that backend's default — and
        the panel's picker is refreshes with the new list."""
        from .chat import (
            available_models_for_backend,
            default_model_for_backend,
            resolve_chat_client,
        )

        normalized = backend.lower()
        self.settings.selected_chat_backend = normalized
        available_models = available_models_for_backend(self.settings, normalized)
        if self.settings.selected_model not in available_models:
            self.settings.selected_model = default_model_for_backend(
                self.settings, normalized
            )
        self.settings.save()
        self.chat_client = resolve_chat_client(self.settings)
        self.modelChoicesChanged.emit(list(available_models), self.settings.selected_model)
        print(f"💬 Chat backend: {normalized} (model {self.chat_client.model})")

    def _on_transcription_provider_selected(self, provider_identifier: str):
        self.settings.save()
        try:
            from threading import Thread  # noqa: F401 — provider swap happens lazily

            from .transcription import resolve_transcription_provider

            new_provider = resolve_transcription_provider(
                provider_identifier, self.settings.proxy_base_url
            )
            self.dictation_manager.transcription_provider = new_provider
            print(f"🎙️ Transcription provider: {provider_identifier}")
        except Exception as provider_error:  # unknown provider stays put
            print(f"⚠️ Provider swap failed: {provider_error}")

    def _on_clicky_cursor_preference_changed(self, enabled: bool):
        self.settings.is_clicky_cursor_enabled = enabled
        self.settings.save()
        if not enabled:
            # Transient mode: hide now; the next push-to-talk temporarily shows it
            self.overlayDismissRequested.emit()


class _ResponsePipelineResult:
    """Mutable result carried from the worker thread back into the manager."""

    def __init__(self):
        self.full_response_text = ""
        self.screen_captures = []


_STATUS_TEXT_FOR_STATE = {
    CompanionVoiceState.IDLE: "idle — hold ctrl + alt to talk",
    CompanionVoiceState.LISTENING: "listening…",
    CompanionVoiceState.PROCESSING: "thinking…",
    CompanionVoiceState.RESPONDING: "speaking…",
}
