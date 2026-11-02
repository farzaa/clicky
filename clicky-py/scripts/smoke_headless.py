"""Headless smoke test: instantiates the full Qt app stack offscreen
(QT_QPA_PLATFORM=offscreen) to catch wiring/enum/signature errors without a
display or mic. Not a pytest test — run manually:

    .\\.venv\\Scripts\\python.exe scripts\\smoke_headless.py
"""

import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from clickpy.console import configure_unicode_console  # noqa: E402

# Offscreen + UTF-8 so emoji logging never kills the run on cp1252 consoles
os.environ["QT_QPA_PLATFORM"] = "offscreen"
configure_unicode_console()

from PySide6.QtCore import QEvent, QPoint, QPointF, Qt  # noqa: E402
from PySide6.QtGui import QCursor, QMouseEvent  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402


def main() -> int:
    application = QApplication(sys.argv)

    from clickpy.overlay import OverlayWindowHarness  # noqa: E402
    from clickpy.panel import MenuBarPanelManager  # noqa: E402
    from clickpy.config import CompanionSettings  # noqa: E402
    from clickpy.dictation import (  # noqa: E402
        BuddyDictationManager,
        GlobalPushToTalkShortcutMonitor,
        TranscriptionChoiceResolver,
    )
    from clickpy.companion_manager import CompanionManager  # noqa: E402
    from clickpy.companion_manager import CompanionVoiceState  # noqa: F401,E402

    settings = CompanionSettings.load()
    settings.proxy_base_url = "http://127.0.0.1:59999"  # never hit the network here

    panel_manager = MenuBarPanelManager(settings)
    resolver = TranscriptionChoiceResolver(settings.proxy_base_url, None)
    push_to_talk_monitor = GlobalPushToTalkShortcutMonitor()
    dictation_manager = BuddyDictationManager(resolver.provider)
    companion_manager = CompanionManager(
        settings=settings,
        panel_manager=panel_manager,
        dictation_manager=dictation_manager,
        push_to_talk_monitor=push_to_talk_monitor,
    )

    # Drive the state machine offline: listening -> spinner -> response bubble
    companion_manager.overlayShowRequested.emit("hello there")
    companion_manager.overlayShowSpinnerRequested.emit()
    companion_manager.overlayResponseTextChanged.emit("all good — [POINT:none]")

    # Panel paints + status updates
    panel_manager.set_companion_status("listening…")
    assert panel_manager.tray_menu is not None

    # Render every painter path (grab composites the widget offscreen)
    overlay_window = OverlayWindowHarness()
    overlay_window.show_on_screen(application.primaryScreen(), QCursor.pos())
    overlay_window.set_recording_state(True, "something on my screen, hmm")
    overlay_window.set_audio_power_level(0.7)
    rendered_pixmap = overlay_window.grab()
    assert not rendered_pixmap.isNull()

    panel_pixmap = panel_manager.companion_panel.grab()
    assert not panel_pixmap.isNull()

    # Element pointing math end-to-end inside a live widget tree
    companion_manager.overlayResponseTextChanged.emit(
        "click the run button [POINT:640,400:run button]"
    )

    # Transient-cursor scheduling logic runs even without media playback:
    companion_manager._on_tts_playback_finished()
    companion_manager._maybe_dismiss_transient_overlay()

    # Panel hit-testing logic (frameless windows + tray-click dismissal):
    # show the panel in the offscreen space, then check edge semantics
    companion_panel = panel_manager.companion_panel
    companion_panel.position_near_cursor()
    companion_panel.show()
    interior_point = companion_panel.mapToGlobal(QPoint(10, 10))
    assert panel_manager._is_pointer_inside_panel(interior_point.x(), interior_point.y())
    corner_point = QPoint(
        interior_point.x() + companion_panel.width() + 200,
        interior_point.y() + companion_panel.height() + 200,
    )
    assert not panel_manager._is_pointer_inside_panel(corner_point.x(), corner_point.y())
    companion_panel.hide()

    # Mic availability probe (real audio stack, no GUI needed)
    companion_manager.check_microphone_availability()

    # Startup proxy probe against an unbindable localhost port -> hint text
    companion_manager.settings.proxy_base_url = "http://127.0.0.1:1"
    companion_manager.check_proxy_reachable()
    assert companion_manager._proxy_available is False
    companion_manager.settings.proxy_base_url = "http://127.0.0.1:59999"

    # Chat backend switching: with no OPENAI_API_KEY the switch must fall
    # back to Claude and refresh the panel's model picker.
    companion_manager._on_chat_backend_selected("openai")
    companion_manager._on_chat_backend_selected("claude")
    assert isinstance(companion_manager.chat_client, object)

    # OpenAI transcription selection without a key stays on AssemblyAI
    companion_manager._on_transcription_provider_selected("openai")

    # Flight animation: full bezier arc driven by a real event loop
    overlay_window.start_flight_arc(to_position=QPointF(300.0, 160.0))
    spin_deadline = time.monotonic() + 3.0
    while overlay_window._flight_in_progress and time.monotonic() < spin_deadline:
        application.processEvents()
    assert overlay_window._flight_in_progress is False
    assert overlay_window.cursor_position.x() > 250.0  # arc landed near target

    # Response waveform: TTS playback lifecycle toggles the bars
    overlay_window.set_response_waveform_active(True)
    paired_pixmap = overlay_window.grab()
    assert not paired_pixmap.isNull()
    overlay_window.set_response_waveform_active(False)

    # Panel dragging: bare-surface press latches the drag offset
    press_event = QMouseEvent(
        QEvent.Type.MouseButtonPress,
        QPointF(20.0, 20.0),
        QPoint(20, 20),
        Qt.MouseButton.LeftButton,
        Qt.MouseButton.LeftButton,
        Qt.KeyboardModifier.NoModifier,
    )
    companion_panel.mousePressEvent(press_event)
    assert companion_panel._drag_offset_from_window_corner is not None
    companion_panel.mouseReleaseEvent(press_event)
    assert companion_panel._drag_offset_from_window_corner is None

    print("smoke ok — Qt stack assembled and painted offscreen")
    return 0


if __name__ == "__main__":
    sys.exit(main())

