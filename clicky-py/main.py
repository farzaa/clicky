"""clicky-py — Windows port of the Clicky macOS menu bar companion.

Entry point. Owns the QApplication, builds the overlay + panel + manager,
and connects the manager's signals to the overlay widgets (CompanionManager
stays transport-agnostic; this file is the UI adapter, like leanring_buddyApp
+ CompanionAppDelegate in the Swift project).
"""

from __future__ import annotations

import sys

from PySide6.QtCore import QCoreApplication, Qt
from PySide6.QtGui import QCursor
from PySide6.QtWidgets import QApplication, QMessageBox, QWidget

from clickpy.companion_manager import CompanionManager, CompanionVoiceState
from clickpy.config import CompanionSettings
from clickpy.console import configure_unicode_console
from clickpy.dictation import (
    BuddyDictationManager,
    GlobalPushToTalkShortcutMonitor,
    TranscriptionChoiceResolver,
)
from clickpy.overlay import OverlayWindowHarness
from clickpy.panel import MenuBarPanelManager


class OverlayController(QWidget):
    """Creates/drives the one visible OverlayWindowHarness for CompanionManager's
    signals. Owns the transient visibility logic that Swift split across
    OverlayWindowManager + BlueCursorView."""

    def __init__(self, companion_manager: CompanionManager, settings: CompanionSettings, parent=None):
        super().__init__(parent)
        self.companion_manager = companion_manager
        self.settings = settings
        self.overlay_window: OverlayWindowHarness | None = None
        self._capture_guard_active = False

        companion_manager.overlayShowRequested.connect(self._on_show_requested)
        companion_manager.overlayShowSpinnerRequested.connect(self._on_show_spinner)
        companion_manager.overlayResponseTextChanged.connect(self._on_response_text)
        companion_manager.overlayAudioPowerChanged.connect(self._on_audio_power)
        companion_manager.overlayDismissRequested.connect(self.dismiss)
        companion_manager.pointingTargetRequested.connect(self.fly_to_target)
        companion_manager.captureRequested.connect(self._on_capture_requested)
        companion_manager.voiceStateChanged.connect(self._on_voice_state_changed)

    # -- overlay lifecycle ---------------------------------------------------

    def _ensure_overlay_exists(self, screen=None):
        if self.overlay_window is None:
            self.overlay_window = OverlayWindowHarness()
            if screen is None:
                screen = (
                    QApplication.screenAt(QCursor.pos()) or QApplication.primaryScreen()
                )
            self.overlay_window.show_on_screen(screen, QCursor.pos())

    def dismiss(self):
        if self.overlay_window is not None and not self._capture_guard_active:
            self.overlay_window.hide_overlay()

    # -- state handlers ------------------------------------------------------

    def _on_show_requested(self, live_transcript: str):
        if self._capture_guard_active:
            return
        self._ensure_overlay_exists()
        # A new interaction parks the buddy under the user's pointer
        # immediately (Swift's jump-back-to-cursor before recording starts).
        self.overlay_window.reset_cursor_to_position(QCursor.pos())
        self.overlay_window.set_recording_state(True, live_transcript)

    def _on_voice_state_changed(self, new_state: str):
        """When the interaction ends, the buddy flies home to the user's
        pointer — the Swift BlueCursorView behavior after playback + pointing
        complete."""
        from PySide6.QtCore import QPointF

        if new_state == CompanionVoiceState.IDLE and self.overlay_window is not None:
            self.fly_to_target(QCursor.pos().x(), QCursor.pos().y())

    def _on_show_spinner(self):
        if self.overlay_window is not None:
            self.overlay_window.set_processing_state(True)

    def _on_response_text(self, response_text: str):
        if self.overlay_window is not None:
            self.overlay_window.set_processing_state(False)
            self.overlay_window.set_response_text(response_text)

    def _on_audio_power(self, power_level: float):
        if self.overlay_window is not None:
            self.overlay_window.set_audio_power_level(power_level)

    def fly_to_target(self, global_x: float, global_y: float):
        """Recreates the overlay on the target screen if needed, then starts
        the bezier flight arc — the multi-monitor mapping half of the Swift
        BlueCursorView flight logic."""
        from PySide6.QtCore import QPointF

        target_screen = (
            QApplication.screenAt(QPoint(int(global_x), int(global_y)))
            or QApplication.primaryScreen()
        )
        self._ensure_overlay_exists()
        if self.overlay_window.screen_target is not target_screen:
            # The pointing target lives on another monitor: rebuild the
            # overlay there so the clamp window lets the buddy land properly.
            self.overlay_window.hide_overlay()
            self.overlay_window = None
            self._ensure_overlay_exists(target_screen)
        self.overlay_window.set_global_target_position(QPointF(global_x, global_y))

    def _on_capture_requested(self, capture_holder: dict, completion_event):
        """Executes on the main thread, where widget calls are safe. Hides the
        overlay, grabs the screenshots, then reveals the overlay again and
        resolves the waiting worker thread."""
        from clickpy.screen_capture import capture_all_screens_as_jpeg

        try:
            did_hide = False
            if self.overlay_window is not None and self.overlay_window.isVisible():
                self.overlay_window.hide_overlay()
                did_hide = True
                # Two event-loop turns let Qt actually present the scene
                # without our overlay before mss reads the screen.
                QApplication.processEvents()
                QApplication.processEvents()
            capture_holder["captures"] = capture_all_screens_as_jpeg()
        except Exception as capture_error:
            capture_holder["error"] = capture_error
        finally:
            completion_event.set()

        # Bring the overlay back for the spinner/response — unless the user
        # already dismissed it deliberately.
        active_states = (
            CompanionVoiceState.LISTENING,
            CompanionVoiceState.PROCESSING,
            CompanionVoiceState.RESPONDING,
        )
        companion_state = self.companion_manager.voice_state
        if did_hide and companion_state in active_states:
            self._capture_guard_active = False
            if self.overlay_window is None:
                self._ensure_overlay_exists()
            self.overlay_window.set_processing_state(
                companion_state == CompanionVoiceState.PROCESSING
            )


def main() -> int:
    configure_unicode_console()
    QCoreApplication.setAttribute(Qt.ApplicationAttribute.AA_EnableHighDpiScaling, True)    application = QApplication(sys.argv)
    application.setApplicationName("clicky-py")
    application.setQuitOnLastWindowClosed(False)  # tray app: quitting is explicit

    settings = CompanionSettings.load()

    panel_manager = MenuBarPanelManager(settings)

    resolver = TranscriptionChoiceResolver(
        proxy_base_url=settings.proxy_base_url,
        provider_choice=_provider_choice_from_environment(),
    )
    push_to_talk_monitor = GlobalPushToTalkShortcutMonitor(
        hold_keys=settings.push_to_talk_hold_keys
    )
    dictation_manager = BuddyDictationManager(resolver.provider)
    companion_manager = CompanionManager(
        settings=settings,
        panel_manager=panel_manager,
        dictation_manager=dictation_manager,
        push_to_talk_monitor=push_to_talk_monitor,
    )

    overlay_controller = OverlayController(companion_manager, settings)

    # Keyboard push-to-talk monitor
    push_to_talk_monitor.start_monitoring()
    panel_manager.show_status_bar_icon()

    # Surface mic availability up front instead of failing mid-push
    companion_manager.check_microphone_availability()
    # Same for the Worker proxy — down proxy = actionable panel hint
    companion_manager.check_proxy_reachable()

    def quit_everything():
        companion_manager._response_worker_cancelled = True
        dictation_manager.cancel_dictation()
        panel_manager.teardown()
        application.quit()

    panel_manager.quitRequested.connect(quit_everything)

    return application.exec()


def _provider_choice_from_environment() -> str | None:
    import os

    return os.environ.get("VOICE_TRANSCRIPTION_PROVIDER")


if __name__ == "__main__":
    try:
        exit_code = main()
    except Exception as fatal_error:
        # Show failures visibly — a tray app with no window otherwise dies silently.
        hidden_app = QApplication.instance() or QApplication(sys.argv)
        QMessageBox.critical(
            None,
            "clicky-py failed to start",
            f"{type(fatal_error).__name__}: {fatal_error}",
        )
        raise
    sys.exit(exit_code)
