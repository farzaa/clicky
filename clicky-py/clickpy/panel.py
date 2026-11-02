"""Menu-bar panel + system tray icon — port of MenuBarPanelManager.swift and
CompanionPanelView.swift.

On Windows the status-bar home is the system tray (the equivalent of
NSStatusItem). Clicking the tray icon toggles a small frameless dark panel
showing the companion status, the push-to-talk shortcut, the model picker,
and quit — the same content CompanionPanelView renders in SwiftUI.
"""

from __future__ import annotations

from typing import Optional

from PySide6.QtCore import QObject, QPoint, QSize, Qt, Signal
from PySide6.QtGui import (
    QBrush,
    QAction,
    QColor,
    QIcon,
    QPainter,
    QPainterPath,
    QPen,
    QPixmap,
)
from PySide6.QtWidgets import (
    QApplication,
    QCheckBox,
    QComboBox,
    QFrame,
    QHBoxLayout,
    QLabel,
    QMenu,
    QPushButton,
    QSizePolicy,
    QSystemTrayIcon,
    QVBoxLayout,
    QWidget,
)

from .config import CompanionSettings
from .design_system import Colors, CornerRadius, FontSizes


def build_buddy_icon() -> QIcon:
    """Draws the buddy triangle on a transparent rounded-square pixmap — the
    tray icon stand-in for the NSStatusItem image."""
    icon_pixmap = QPixmap(QSize(64, 64))
    icon_pixmap.fill(Qt.GlobalColor.transparent)
    painter = QPainter(icon_pixmap)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)

    triangle_path = QPainterPath()
    triangle_path.moveTo(32.0, 12.0)
    triangle_path.lineTo(50.0, 48.0)
    triangle_path.lineTo(14.0, 48.0)
    triangle_path.closeSubpath()
    painter.setPen(
        QPen(
            QBrush(QColor(Colors.buddy_cursor)),
            6.0,
            Qt.PenStyle.SolidLine,
            Qt.PenCapStyle.RoundCap,
            Qt.PenJoinStyle.RoundJoin,
        )
    )
    painter.setBrush(QBrush(QColor(Colors.buddy_cursor)))
    painter.drawPath(triangle_path)
    painter.setPen(Qt.PenStyle.NoPen)
    painter.setBrush(QBrush(QColor("#0f2536")))
    painter.drawEllipse(32.0, 36.0, 4.0, 4.0)
    painter.end()
    return QIcon(icon_pixmap)


PANEL_STYLESHEET = f"""
#ClickyPanel {{
    background: {Colors.surface1};
    border: 1px solid {Colors.border_subtle};
    border-radius: {CornerRadius.panel}px;
}}
#ClickyPanel QLabel {{
    color: {Colors.text_secondary};
    font-size: {FontSizes.caption}px;
}}
#ClickyPanel QLabel#ClickyTitle {{
    color: {Colors.text_primary};
    font-size: {FontSizes.title}px;
    font-weight: 600;
}}
#ClickyPanel QLabel#ClickyStatus {{
    color: {Colors.text_primary};
    font-size: {FontSizes.body}px;
}}
#ClickyPanel QComboBox {{
    background: {Colors.surface3};
    color: {Colors.text_primary};
    border: 1px solid {Colors.border_subtle};
    border-radius: {CornerRadius.small}px;
    padding: 4px 8px;
}}
#ClickyPanel QPushButton {{
    background: {Colors.surface3};
    color: {Colors.text_primary};
    border: 1px solid {Colors.border_subtle};
    border-radius: {CornerRadius.small}px;
    padding: 6px 10px;
}}
#ClickyPanel QPushButton:hover {{
    background: {Colors.surface4};
}}
#ClickyPanel QPushButton:disabled {{
    color: {Colors.text_tertiary};
}}
#ClickyPanel QCheckBox {{
    color: {Colors.text_secondary};
}}
#ClickyPanel QCheckBox::indicator {{
    width: 14px; height: 14px;
    border-radius: 3px;
    border: 1px solid {Colors.border_strong};
    background: {Colors.surface3};
}}
#ClickyPanel QCheckBox::indicator:checked {{
    background: {Colors.accent};
}}
"""


class CompanionPanelView(QWidget):
    """The little dark panel: title, status line, model picker, options."""

    def __init__(self, settings: CompanionSettings, parent=None):
        super().__init__(parent)
        self.setObjectName("ClickyPanel")
        self.setStyleSheet(PANEL_STYLESHEET)
        self.setWindowFlags(
            Qt.WindowType.FramelessWindowHint
            | Qt.WindowType.Tool
            | Qt.WindowType.WindowStaysOnTopHint
        )
        self.setFixedSize(QSize(300, 210))

        layout = QVBoxLayout(self)
        layout.setContentsMargins(14, 12, 14, 12)
        layout.setSpacing(8)

        title_label = QLabel("clicky")
        title_label.setObjectName("ClickyTitle")
        layout.addWidget(title_label)

        self.status_label = QLabel("idle — hold ctrl + alt to talk")
        self.status_label.setObjectName("ClickyStatus")
        self.status_label.setWordWrap(True)
        layout.addWidget(self.status_label)

        picker_row = QHBoxLayout()
        model_caption = QLabel("model")
        self.model_combo_box = QComboBox()
        self.model_combo_box.addItems(list(settings.available_models))
        if settings.selected_model in settings.available_models:
            self.model_combo_box.setCurrentText(settings.selected_model)
        picker_row.addWidget(model_caption)
        picker_row.addWidget(self.model_combo_box, 1)

        transcription_caption = QLabel("transcription")
        self.transcription_combo_box = QComboBox()
        self.transcription_combo_box.addItems(["AssemblyAI", "OpenAI"])
        picker_row.addSpacing(6)
        picker_row.addWidget(transcription_caption)
        picker_row.addWidget(self.transcription_combo_box, 1)
        layout.addLayout(picker_row)

        self.show_cursor_check_box = QCheckBox("show clicky cursor")
        self.show_cursor_check_box.setChecked(settings.is_clicky_cursor_enabled)
        layout.addWidget(self.show_cursor_check_box)

        layout.addStretch(1)

        divider = QFrame()
        divider.setFrameShape(QFrame.Shape.HLine)
        layout.addWidget(divider)

        bottom_row = QHBoxLayout()
        hint_label = QLabel("hold ctrl + alt to talk")
        hint_label.setWordWrap(True)
        bottom_row.addWidget(hint_label, 1)

        # Push-to-talk button — hands-free alternative to the keyboard combo
        # (the macOS app has the same alternative in its panel).
        self.hold_to_talk_button = QPushButton("hold to talk")
        self.hold_to_talk_button.setSizePolicy(QSizePolicy.Policy.Fixed, QSizePolicy.Policy.Fixed)
        bottom_row.addWidget(self.hold_to_talk_button)

        self.quit_button = QPushButton("quit")
        self.quit_button.setSizePolicy(QSizePolicy.Policy.Fixed, QSizePolicy.Policy.Fixed)
        bottom_row.addWidget(self.quit_button)
        layout.addLayout(bottom_row)

    def set_status_text(self, status_text: str):
        self.status_label.setText(status_text)

    def position_near_cursor(self):
        """Opens the panel near its tray click without wandering off-screen."""
        mouse_position = self.cursor().pos()
        target_screen = (
            QApplication.screenAt(mouse_position) or QApplication.primaryScreen()
        )
        available_geometry = target_screen.availableGeometry()

        # Park just below the click point, nudged back inside the screen.
        panel_position = QPoint(mouse_position.x(), mouse_position.y() + 14)
        panel_position.setX(
            min(panel_position.x(), available_geometry.right() - self.width() - 8)
        )
        panel_position.setY(
            min(panel_position.y(), available_geometry.bottom() - self.height() - 8)
        )
        self.move(panel_position)


class MenuBarPanelManager(QObject):
    """Tray icon + panel lifecycle, mirroring MenuBarPanelManager."""

    companionPanelToggled = Signal(bool)  # visible
    modelSelected = Signal(str)
    transcriptionProviderSelected = Signal(str)
    clickyCursorPreferenceChanged = Signal(bool)
    quitRequested = Signal()
    holdToTalkPressed = Signal()
    holdToTalkReleased = Signal()

    def __init__(self, settings: CompanionSettings, parent=None):
        super().__init__(parent)
        self.settings = settings
        self._global_mouse_listener: Optional[object] = None

        self.tray_icon = QSystemTrayIcon(build_buddy_icon(), self)
        self.tray_menu = self._build_tray_menu()
        self.tray_icon.setContextMenu(self.tray_menu)
        # Left click toggles the panel (Windows tray convention); right click
        # opens the context menu.
        self.tray_icon.activated.connect(self._on_tray_activated)

        self.companion_panel = CompanionPanelView(settings)
        self._install_click_outside_dismissal()
        self._wire_panel_signals()

    def _build_tray_menu(self) -> QMenu:
        tray_menu = QMenu()
        show_panel_action = QAction("Show companion panel", tray_menu)
        show_panel_action.triggered.connect(lambda: self.toggle_companion_panel())
        tray_menu.addAction(show_panel_action)

        show_cursor_action = QAction("Show clicky cursor", tray_menu, checkable=True)
        show_cursor_action.setChecked(self.settings.is_clicky_cursor_enabled)
        show_cursor_action.toggled.connect(self.clickyCursorPreferenceChanged.emit)
        tray_menu.addAction(show_cursor_action)

        tray_menu.addSeparator()
        quit_action = QAction("Quit clicky", tray_menu)
        quit_action.triggered.connect(self.quitRequested.emit)
        tray_menu.addAction(quit_action)
        return tray_menu

    def _wire_panel_signals(self):
        self.companion_panel.model_combo_box.currentTextChanged.connect(
            self.modelSelected.emit
        )
        self.companion_panel.transcription_combo_box.currentTextChanged.connect(
            self._on_transcription_selected
        )
        self.companion_panel.show_cursor_check_box.toggled.connect(
            self.clickyCursorPreferenceChanged.emit
        )
        self.companion_panel.quit_button.clicked.connect(self.quitRequested.emit)
        self.companion_panel.hold_to_talk_button.pressed.connect(
            self.holdToTalkPressed.emit
        )
        self.companion_panel.hold_to_talk_button.released.connect(
            self.holdToTalkReleased.emit
        )

    def _on_transcription_selected(self, provider_display_name: str):
        # UI shows friendly names; the manager layer expects identifiers
        provider_identifier = provider_display_name.lower()
        self.transcriptionProviderSelected.emit(provider_identifier)

    def _install_click_outside_dismissal(self):
        """Global click monitor: dismiss the panel when clicking elsewhere —
        the Qt counterpart of the Swift installClickOutsideMonitor."""
        try:
            from pynput import mouse as pynput_mouse

            def on_mouse_click(x, y, button, pressed):
                if (
                    button == pynput_mouse.Button.left
                    and pressed
                    and self.is_companion_panel_visible()
                ):
                    if not self._is_pointer_inside_panel(x, y):
                        self.companion_panel.hide()
                        self.companionPanelToggled.emit(False)

            self._global_mouse_listener = pynput_mouse.Listener(on_click=on_mouse_click)
            self._global_mouse_listener.start()
        except Exception as listener_error:
            print(f"[panel] outside-click dismissal unavailable: {listener_error}")

    def _is_pointer_inside_panel(self, global_x: int, global_y: int) -> bool:
        panel_global_rect = self.companion_panel.geometry()
        local_top_left = self.companion_panel.mapToGlobal(QPoint(0, 0))
        panel_global_rect.translate(
            local_top_left - self.companion_panel.mapToGlobal(QPoint(0, 0))
        )
        panel_global_rect.moveTopLeft(local_top_left)
        return panel_global_rect.contains(global_x, global_y)

    def show_status_bar_icon(self):
        self.tray_icon.show()
        self.tray_icon.setToolTip("clicky")

    def is_companion_panel_visible(self) -> bool:
        return self.companion_panel.isVisible()

    def toggle_companion_panel(self):
        if self.companion_panel.isVisible():
            self.companion_panel.hide()
            self.companionPanelToggled.emit(False)
        else:
            self.companion_panel.position_near_cursor()
            self.companion_panel.show()
            self.companion_panel.raise_()
            # WindowStaysOnTopHint panels should not steal focus from the user's
            # app — show without activation, matching the Swift non-activating
            # NSPanel behavior.
            self.companionPanelToggled.emit(True)

    def _on_tray_activated(self, reason):
        if reason == QSystemTrayIcon.ActivationReason.Trigger:
            self.toggle_companion_panel()

    def set_companion_status(self, status_text: str):
        self.companion_panel.set_status_text(status_text)

    def teardown(self):
        if self._global_mouse_listener is not None:
            self._global_mouse_listener.stop()
        self.tray_icon.hide()
