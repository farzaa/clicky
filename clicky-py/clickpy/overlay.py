"""Transparent overlay hosting the blue cursor companion — port of
OverlayWindow.swift + CompanionResponseOverlay.swift + BlueCursorView.

One fullscreen transparent always-on-top window per target screen. Painted
entirely with QPainter:
- the rounded blue triangle buddy
- a dark speech bubble showing the transcript while listening (port of the
  live transcript bubble) or the response while speaking
- a waveform that scales with the mic power level
- a spinner while Claude is processing
- the bezier arc flight animation with the same tangent-heading rotation as
  the Swift implementation, plus a point-up/down flip if the target is up
  (Swift's drawCursor rotated toward the arc's tangent).

Everything is drawn in the window's own coordinate space; the window covers
one screen, and CompanionManager recreates it on whichever screen the
pointing target lives on (PORT SIMPLIFICATION: rather than the Swift
per-screen window farm, the MVP spawns one overlay window at a time).
"""

from __future__ import annotations

import math
import time

from PySide6.QtCore import QPoint, QPointF, QRectF, QTimer, Qt, Signal
from PySide6.QtGui import (
    QBrush,
    QColor,
    QFont,
    QFontMetricsF,
    QPainter,
    QPainterPath,
    QPen,
)
from PySide6.QtWidgets import QApplication, QWidget

from .design_system import Colors, CornerRadius
from .element_pointing import (
    flight_control_point,
    flight_duration_seconds,
    quadratic_bezier_point,
    quadratic_bezier_tangent_degrees,
)


class OverlayWindowHarness(QWidget):
    """Fullscreen transparent, click-through, always-on-top overlay for one
    screen. Signals mirror the observable state Swift exposed on
    OverlayWindowManager."""

    flightFinished = Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowFlags(
            Qt.WindowType.FramelessWindowHint
            | Qt.WindowType.WindowStaysOnTopHint
            | Qt.WindowType.Tool
            | Qt.WindowType.WindowTransparentForInput
            | Qt.WindowType.NoDropShadowWindowHint
        )
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground, True)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating, True)

        # Paint state --------------------------------------------------
        self.cursor_position = QPointF(0, 0)
        self.triangle_rotation_degrees = 0.0
        self.response_text = ""
        self.live_transcript_text = ""
        self.is_recording = False
        self.is_processing = False
        self.audio_power_level = 0.0
        # When TTS is playing, the waveform bars animate above the response
        # bubble (Swift's CompanionResponseOverlay waveform)
        self.response_waveform_active = False
        self._waveform_phase = 0.0
        self.screen_target = None

        # Flight animation --------------------------------------------
        self._flight_start_position: QPointF | None = None
        self._flight_end_position: QPointF | None = None
        self._flight_control_point: QPointF | None = None
        self._flight_elapsed_timer: QTimer | None = None
        self._flight_duration_seconds = 0.0
        self._flight_start_timestamp_ms = 0
        self._flight_in_progress = False

        # Waveform + spinner ticking
        self._repaint_timer = QTimer(self)
        self._repaint_timer.setInterval(33)  # ~30 fps painting
        self._repaint_timer.timeout.connect(self._on_repaint_tick)

    # -- placement ------------------------------------------------------

    @staticmethod
    def screen_for_global_point(global_point: QPointF, fallback_screen=None):
        screen = QApplication.screenAt(QPoint(int(global_point.x()), int(global_point.y())))
        if screen is None:
            screen = fallback_screen or QApplication.primaryScreen()
        return screen

    def show_on_screen(self, screen, start_position: QPointF):
        """Resizes/repositions to cover `screen` and parks the buddy at
        start_position (global logical coordinates)."""
        self.screen_target = screen
        screen_geometry = screen.geometry()
        self.setGeometry(screen_geometry)
        self.cursor_position = QPointF(start_position.x(), start_position.y())
        self.setFixedSize(screen_geometry.size())
        self.show()
        self._repaint_timer.start()

    def hide_overlay(self):
        self._repaint_timer.stop()
        self.hide()

    def set_global_target_position(self, global_point: QPointF) -> None:
        """If the buddy is currently parked elsewhere, start a flight arc to
        the target. If the target is on another screen, CompanionManager
        recreates the overlay there first."""
        target_local = QPointF(
            global_point.x() - self.geometry().x(), global_point.y() - self.geometry().y()
        )
        self.start_flight_arc(to_position=target_local)

    # -- state setters (called from CompanionManager signals) -----------

    def set_recording_state(self, is_recording: bool, live_transcript: str):
        self.is_recording = is_recording
        self.live_transcript_text = live_transcript
        self.update()

    def set_processing_state(self, is_processing: bool):
        self.is_processing = is_processing
        self.update()

    def set_response_text(self, response_text: str):
        self.response_text = response_text
        self.update()

    def set_audio_power_level(self, power_level: float):
        self.audio_power_level = power_level
        self.update()

    def set_response_waveform_active(self, active: bool):
        self.response_waveform_active = active
        self.update()

    # -- flight animation -------------------------------------------------

    def start_flight_arc(self, to_position: QPointF):
        """Animates the buddy along a quadratic bezier arc from its current
        position to to_position, rotating to follow the arc tangent — direct
        port of animateBezierFlightArc in OverlayWindow.swift."""
        start_position = QPointF(self.cursor_position)
        target_position = self._clamp_into_screen(to_position)
        control_point = flight_control_point(
            (start_position.x(), start_position.y()),
            (target_position.x(), target_position.y()),
        )

        self._flight_start_position = QPointF(start_position)
        self._flight_end_position = QPointF(target_position)
        self._flight_control_point = QPointF(control_point[0], control_point[1])
        self._flight_duration_seconds = flight_duration_seconds(
            (start_position.x(), start_position.y()),
            (target_position.x(), target_position.y()),
        )
        self._flight_start_timestamp_ms = int(time_ms())

        self._flight_elapsed_timer = QTimer(self)
        self._flight_elapsed_timer.setInterval(16)
        self._flight_elapsed_timer.timeout.connect(self._on_flight_tick)
        self._flight_elapsed_timer.start()
        self._flight_in_progress = True

    def _clamp_into_screen(self, position: QPointF) -> QPointF:
        """Keeps the buddy inside the overlay's screen bounds with a margin,
        so pointing at screen edges never parks it off display."""
        margin = 40.0
        width = self.geometry().width()
        height = self.geometry().height()
        clamped_x = min(max(position.x(), margin), max(margin, width - margin))
        clamped_y = min(max(position.y(), margin), max(margin, height - margin))
        return QPointF(clamped_x, clamped_y)

    def _on_flight_tick(self):
        if (
            self._flight_start_position is None
            or self._flight_end_position is None
            or self._flight_control_point is None
        ):
            self._stop_flight(cleared=True)
            return

        elapsed_ratio = (time_ms() - self._flight_start_timestamp_ms) / (
            self._flight_duration_seconds * 1000.0
        )
        travel_param_t = min(1.0, max(0.0, elapsed_ratio))

        bezier_point = quadratic_bezier_point(
            (
                self._flight_start_position.x(),
                self._flight_start_position.y(),
            ),
            (
                self._flight_control_point.x(),
                self._flight_control_point.y(),
            ),
            (self._flight_end_position.x(), self._flight_end_position.y()),
            travel_param_t,
        )
        tangent_degrees = quadratic_bezier_tangent_degrees(
            (
                self._flight_start_position.x(),
                self._flight_start_position.y(),
            ),
            (
                self._flight_control_point.x(),
                self._flight_control_point.y(),
            ),
            (self._flight_end_position.x(), self._flight_end_position.y()),
            travel_param_t,
        )
        self.cursor_position = QPointF(bezier_point[0], bezier_point[1])
        self.triangle_rotation_degrees = tangent_degrees
        self.update()

        if travel_param_t >= 1.0:
            self._stop_flight(cleared=False)
            self.flightFinished.emit()

    def _stop_flight(self, cleared: bool):
        if self._flight_elapsed_timer is not None:
            self._flight_elapsed_timer.stop()
            self._flight_elapsed_timer = None
        self._flight_in_progress = False
        if cleared:
            self._flight_start_position = None
            self._flight_end_position = None
            self._flight_control_point = None

    def reset_cursor_to_position(self, global_point: QPointF):
        """Parks the buddy instantly (used when a new push-to-talk starts —
        the companion jumps to the speech bubble near the user's pointer,
        mirroring the Swift 'jump back to cursor' behavior)."""
        local_point = QPointF(
            global_point.x() - self.geometry().x(), global_point.y() - self.geometry().y()
        )
        self.cursor_position = self._clamp_into_screen(local_point)
        self.triangle_rotation_degrees = 0.0
        self.update()

    def _on_repaint_tick(self):
        # Drives the waveform wave and the spinner rotation continuously
        self._waveform_phase += 0.25
        if not self._flight_in_progress:
            self.update()

    # -- painting -----------------------------------------------------------

    def paintEvent(self, _event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        self._draw_buddy_and_chrome(painter)

    def _draw_buddy_and_chrome(self, painter: QPainter):
        cursor_point = self.cursor_position

        # Speech bubble: transcript while listening, response while speaking
        bubble_text = self._current_bubble_text()
        bubble_rect = None
        if bubble_text:
            bubble_rect = self._compute_bubble_rect(cursor_point, bubble_text)

        # Keep the cursor from disappearing behind the bubble
        if self.is_recording or self.response_waveform_active:
            self._draw_waveform(painter, bubble_rect)
        if self.is_processing:
            self._draw_spinner(painter, cursor_point)
        if bubble_text and bubble_rect is not None:
            self._draw_speech_bubble(painter, bubble_rect, bubble_text)
        self._draw_buddy_cursor(painter, cursor_point)

    def _current_bubble_text(self) -> str:
        if self.is_recording:
            return self.live_transcript_text
        if self.is_processing:
            return ""
        return self.response_text

    def _compute_bubble_rect(self, cursor_point: QPointF, text: str) -> QRectF:
        """Bubble floats above the buddy like the macOS version."""
        max_bubble_width = 360.0
        font = QFont()
        font.setPointSizeF(15.0)
        font_metrics = QFontMetricsF(font)
        text_rectangle = font_metrics.boundingRect(QRectF(0, 0, max_bubble_width, 5000), 0, text)
        bubble_width = text_rectangle.width() + 24.0
        bubble_height = text_rectangle.height() + 20.0
        bubble_top_left_x = cursor_point.x() - bubble_width / 2.0
        bubble_top_left_y = cursor_point.y() - 96.0 - bubble_height
        return QRectF(bubble_top_left_x, bubble_top_left_y, bubble_width, bubble_height)

    def _draw_speech_bubble(self, painter: QPainter, bubble_rect: QRectF, text: str):
        bubble_path = QPainterPath()
        bubble_path.addRoundedRect(bubble_rect, CornerRadius.panel, CornerRadius.panel)
        painter.setBrush(QBrush(QColor(Colors.surface2)))
        painter.setPen(QPen(QColor(Colors.border_subtle), 1.0))
        painter.drawPath(bubble_path)

        # Little tail pointing down at the buddy
        tail_path = QPainterPath()
        tail_start_x = self.cursor_position.x()
        tail_path.moveTo(tail_start_x - 7.0, bubble_rect.bottom() - 0.5)
        tail_path.lineTo(tail_start_x, bubble_rect.bottom() + 9.0)
        tail_path.lineTo(tail_start_x + 7.0, bubble_rect.bottom() - 0.5)
        painter.drawPath(tail_path)

        painter.setPen(QPen(QColor(Colors.text_primary)))
        painter.setFont(QFont("Segoe UI", 15))
        painter.drawText(bubble_rect.adjusted(12, 10, -12, -10), Qt.TextFlag.TextWordWrap, text)

    def _draw_buddy_cursor(self, painter: QPainter, cursor_point: QPointF):
        """The blue triangle buddy — rounded corners, rotation applied during
        flight so the tip leads the direction of travel."""
        painter.save()
        painter.translate(cursor_point)

        triangle_height = 34.0
        triangle_width = 30.0
        triangle_path = QPainterPath()

        # Tip pointing up; rotate() happens around the buddy center
        triangle_path.moveTo(0.0, -triangle_height / 2.0)
        triangle_path.lineTo(triangle_width / 2.0, triangle_height / 2.0)
        triangle_path.lineTo(-triangle_width / 2.0, triangle_height / 2.0)
        triangle_path.closeSubpath()

        # Rounded corners: use composition of stroked+filled outline like the
        # Swift rounded triangle ( approximation with thick pen).
        rounded_triangle = QPainterPath()
        pen = QPen(QColor(Colors.buddy_cursor), 4.0, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap, Qt.PenJoinStyle.RoundJoin)
        pen.setMiterLimit(1)
        rounded_triangle.addPath(triangle_path)
        painter.setPen(pen)
        painter.setBrush(QBrush(QColor(Colors.buddy_cursor)))
        painter.save()
        painter.rotate(self.triangle_rotation_degrees)
        painter.drawPath(rounded_triangle)
        painter.restore()

        # Highlight dot — the little "eye" the macOS buddy carries
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(QBrush(QColor("#0f2536")))
        painter.drawEllipse(QPointF(0.0, 2.0), 3.2, 3.2)
        painter.restore()

    def _draw_waveform(self, painter: QPainter, bubble_rect: QRectF | None):
        """Sagging bars sized by the mic power level, above the bubble."""
        if bubble_rect is None:
            cursor_point = self.cursor_position
            reference_y = cursor_point.y() - 60.0
            reference_x = cursor_point.x()
        else:
            reference_y = bubble_rect.top() - 14.0
            reference_x = bubble_rect.center().x()

        painter.save()
        painter.setPen(Qt.PenStyle.NoPen)
        painter.setBrush(QBrush(QColor(Colors.text_primary)))

        bar_count = 5
        bar_spacing = 7.0
        for bar_index in range(bar_count):
            phase_offset = math.sin(self._waveform_phase + bar_index * 0.9)
            bar_height = max(3.0, 26.0 * self.audio_power_level * (0.6 + 0.4 * abs(phase_offset)))
            bar_x = reference_x + (bar_index - bar_count // 2) * bar_spacing
            bar_rect = QRectF(bar_x - 1.6, reference_y - bar_height / 2.0, 3.2, bar_height)
            painter.drawRoundedRect(bar_rect, 1.6, 1.6)
        painter.restore()

    def _draw_spinner(self, painter: QPainter, cursor_point: QPointF):
        """Arc spinner orbiting the buddy while Claude is thinking."""
        spinner_radius = 26.0
        spinner_span_degrees = (self._waveform_phase * 8.0) % 360.0

        painter.save()
        pen = QPen(QColor(Colors.accent), 3.0, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap)
        painter.setPen(pen)
        center_point = QPointF(cursor_point.x(), cursor_point.y() - 44.0)
        spinner_rect = QRectF(
            center_point.x() - spinner_radius,
            center_point.y() - spinner_radius,
            spinner_radius * 2.0,
            spinner_radius * 2.0,
        )
        painter.drawArc(
            spinner_rect,
            int(spinner_span_degrees * 16.0),
            int(90.0 * 16.0),
        )
        painter.restore()


def time_ms() -> float:
    """Monotonic milliseconds — QTimer-driven animations need a stable clock.
    (In Swift this was Date().timeIntervalSince*; python time.monotonic.)"""
    return time.monotonic() * 1000.0
