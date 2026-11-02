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

from clickpy.companion_manager import CompanionManager
from clickpy.config import CompanionSettings
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
        companion_manager.overlayCaptureGuardRequested.connect(self._set_capture_guard)

    # -- overlay lifecycle ---------------------------------------------------

    def _ensure_overlay_exists(self):
        if self.overlay_window is None:
            self.overlay_window = OverlayWindowHarness()
            screen = QApplication.screenAt(QCursor.pos()) or QApplication.primaryScreen()
            self.overlay_window.show_on_screen(screen, QCursor.pos())

    def dismiss(self):
        if self.overlay_window is not None and not self._capture_guard_active:
            self.overlay_window.hide_overlay()

    # -- state handlers ------------------------------------------------------

    def _on_show_requested(self, live_transcript: str):
        if self._capture_guard_active:
            return
        self._ensure_overlay_exists()
        self.overlay_window.set_recording_state(True, live_transcript)

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

        self._ensure_overlay_exists()
        self.overlay_window.set_global_target_position(QPointF(global_x, global_y))

    def _set_capture_guard(self, active: bool):
        """Called by CompanionManager while capturing: hide (so mss does not
        capture the overlay), show again after."""
        if self.overlay_window is None:
            self._capture_guard_active = active
            return
        if active:
            self._capture_guard_active = True
            self.overlay_window.hide_overlay()
        else:
            self._capture_guard_active = False


def main() -> int:
    QCoreApplication.setAttribute(Qt.ApplicationAttribute.AA_EnableHighDpiScaling, True)
    application = QApplication(sys.argv)
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
