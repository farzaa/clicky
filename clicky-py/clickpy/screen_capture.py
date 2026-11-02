"""Multi-monitor screenshot capture — port of CompanionScreenCaptureUtility.

ScreenCaptureKit is macOS-only, so the capture engine is mss + Pillow and
returns JPEG bytes. Everything else mirrors the Swift struct and behavior:
every connected display is captured, each display is labeled with whether
the user's cursor is on it, the cursor screen is sorted first, captures
exclude nothing (the overlay is input-transparent and Qt can't be excluded
from mss anyway — it IS excluded from the image via Win32-style capture of
the desktop below topmost? No: mss captures the desktop including topmost
windows, so when capturing we briefly hide this app's own overlay windows).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Optional


@dataclass
class CompanionScreenCapture:
    """Same fields as the Swift CompanionScreenCapture struct; frames are in
    Qt virtual-desktop logical coordinates (top-left origin) instead of
    AppKit's bottom-left coordinates."""

    image_data: bytes
    label: str
    is_cursor_screen: bool
    display_width_in_logical_points: int
    display_height_in_logical_points: int
    # Display frame as (x, y, width, height) in logical points
    display_frame: tuple[float, float, float, float]
    device_pixel_ratio: float
    screenshot_width_in_pixels: int
    screenshot_height_in_pixels: int


@dataclass
class _MonitorGeometry:
    index: int
    logical_frame: tuple[float, float, float, float]
    device_pixel_ratio: float


def _monitor_geometries() -> list[_MonitorGeometry]:
    """Collects monitor geometry. Qt geometry lives in logical points with
    per-monitor DPI, while mss reports physical pixels. This shim isolates
    the Qt import so tests can run without Qt."""
    from PySide6.QtWidgets import QApplication

    monitors: list[_MonitorGeometry] = []
    for screen_index, qt_screen in enumerate(QApplication.screens()):
        geometry = qt_screen.geometry()
        monitors.append(
            _MonitorGeometry(
                index=screen_index,
                logical_frame=(
                    float(geometry.x()),
                    float(geometry.y()),
                    float(geometry.width()),
                    float(geometry.height()),
                ),
                device_pixel_ratio=qt_screen.devicePixelRatio(),
            )
        )
    return monitors


def _cursor_logical_position() -> Optional[tuple[float, float]]:
    """Cursor position in logical points, or None if unavailable."""
    from PySide6.QtGui import QCursor

    position = QCursor.pos()
    return float(position.x()), float(position.y())


def _contains_point(frame: tuple[float, float, float, float], point: tuple[float, float]) -> bool:
    """Frame is (x, y, width, height); checks containment in logical points.
    Handles negative virtual-desktop origins on Windows (monitor left of the
    primary monitor has x < 0)."""
    x, y, width, height = frame
    point_x, point_y = point
    return x <= point_x < x + width and y <= point_y < y + height


def capture_all_screens_as_jpeg(
    around_capture_callback: Optional[Callable[[bool], None]] = None,
) -> list[CompanionScreenCapture]:
    """Captures all connected displays as JPEG data, labeling each with
    whether the user's cursor is on that screen (cursor screen first).

    around_capture_callback, when supplied, is invoked right before the grab
    sequence with (start=True) and after with (start=False) so the caller can
    hide/show its own overlay windows — the mss equivalent of ScreenCaptureKit's
    excluded windows."""
    import io

    import mss
    from PIL import Image

    monitor_geometries = _monitor_geometries()
    if not monitor_geometries:
        raise RuntimeError("No display available for capture")

    cursor_logical_position = _cursor_logical_position()

    # Sort displays so the cursor screen is always first
    monitor_geometries.sort(
        key=lambda monitor: not (
            cursor_logical_position is not None
            and _contains_point(monitor.logical_frame, cursor_logical_position)
        )
    )

    if around_capture_callback is not None:
        around_capture_callback(start=True)
    try:
        with mss.mss() as screenshot_service:
            captured_screens: list[CompanionScreenCapture] = []
            total_displays = len(monitor_geometries)

            for display_index, monitor in enumerate(monitor_geometries):
                frame_x, frame_y, frame_width, frame_height = monitor.logical_frame
                is_cursor_screen = bool(
                    cursor_logical_position is not None
                    and _contains_point(monitor.logical_frame, cursor_logical_position)
                )

                raw_capture = screenshot_service.grab(
                    {
                        "left": int(frame_x),
                        "top": int(frame_y),
                        "width": int(frame_width),
                        "height": int(frame_height),
                    }
                )

                screen_image = Image.frombytes(
                    "RGB",
                    raw_capture.size,
                    raw_capture.rgb,
                )

                # Downscale so Claude's payload stays small — same 1280 max
                # dimension and 0.8 JPEG quality as the Swift implementation.
                max_dimension = 1280
                if screen_image.width >= screen_image.height:
                    screenshot_width = max_dimension
                    screenshot_height = int(
                        round(max_dimension * (screen_image.height / screen_image.width))
                    )
                else:
                    screenshot_height = max_dimension
                    screenshot_width = int(
                        round(max_dimension * (screen_image.width / screen_image.height))
                    )
                screen_image = screen_image.resize(
                    (screenshot_width, screenshot_height), Image.BILINEAR
                )

                jpeg_stream = io.BytesIO()
                screen_image.save(jpeg_stream, format="JPEG", quality=80)
                jpeg_data = jpeg_stream.getvalue()

                screen_label = _screen_label(
                    display_index, total_displays, is_cursor_screen
                )

                captured_screens.append(
                    CompanionScreenCapture(
                        image_data=jpeg_data,
                        label=screen_label,
                        is_cursor_screen=is_cursor_screen,
                        display_width_in_logical_points=int(frame_width),
                        display_height_in_logical_points=int(frame_height),
                        display_frame=monitor.logical_frame,
                        device_pixel_ratio=monitor.device_pixel_ratio,
                        screenshot_width_in_pixels=screenshot_width,
                        screenshot_height_in_pixels=screenshot_height,
                    )
                )

            if not captured_screens:
                raise RuntimeError("Failed to capture any screen")
            return captured_screens
    finally:
        if around_capture_callback is not None:
            around_capture_callback(start=False)


def _screen_label(display_index: int, total_displays: int, is_cursor_screen: bool) -> str:
    """Same labels as Swift so the shared system prompt keeps working."""
    if total_displays == 1:
        return "user's screen (cursor is here)"
    if is_cursor_screen:
        return (
            f"screen {display_index + 1} of {total_displays} — cursor is on this screen (primary focus)"
        )
    return f"screen {display_index + 1} of {total_displays} — secondary screen"
