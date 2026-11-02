"""Element pointing: [POINT:...] tag parsing and coordinate mapping.

Ports:
- CompanionManager.parsePointingCoordinates (tag grammar + spoken text extraction)
- CompanionManager's screenshot-pixel -> display-point -> global-point math
  (sendTranscriptToClaudeWithScreenshot, lines ~659-674 in the Swift file)

Note on coordinate systems: the macOS code flips Y because AppKit uses a
bottom-left global origin while screenshots use a top-left origin. Qt's
global coordinates are also top-left origin, so on Windows/os-independent
port NO flip is needed — both coordinate spaces already agree. The mapping
is therefore a plain scale by (display physical pixels / screenshot pixels)
plus an offset into the display's frame, which is simpler and testable.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class PointingParseResult:
    """Result of parsing a [POINT:...] tag from Claude's response."""

    # The response text with the [POINT:...] tag removed — this is what gets spoken.
    spoken_text: str
    # The parsed pixel coordinate, or None if Claude said "none" or no tag was found.
    coordinate: Optional[tuple[int, int]]
    # Short label describing the element (e.g. "run button"), or None.
    element_label: Optional[str]
    # Which screen the coordinate refers to (1-based), or None to default to cursor screen.
    screen_number: Optional[int]


# Matches [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
# Anchored to the end of the response, identical to the Swift NSRegularExpression.
_POINT_TAG_PATTERN = re.compile(
    r"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"
)


def parse_pointing_coordinates(response_text: str) -> PointingParseResult:
    """Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of
    Claude's response. Returns the spoken text (tag removed) plus the optional
    coordinate + label + screen number."""
    match = _POINT_TAG_PATTERN.search(response_text)
    if match is None:
        # No tag found at all
        return PointingParseResult(
            spoken_text=response_text,
            coordinate=None,
            element_label=None,
            screen_number=None,
        )

    # Remove the tag from the spoken text
    spoken_text = response_text[: match.start()].rstrip()
    coordinate_x_text, coordinate_y_text = match.group(1), match.group(2)

    # Check if it's [POINT:none] — group 1 is absent in that case
    if coordinate_x_text is None or coordinate_y_text is None:
        return PointingParseResult(
            spoken_text=spoken_text,
            coordinate=None,
            element_label=None,
            screen_number=None,
        )

    coordinate = (int(coordinate_x_text), int(coordinate_y_text))
    element_label = match.group(3)
    screen_number_text = match.group(4)

    return PointingParseResult(
        spoken_text=spoken_text,
        coordinate=coordinate,
        element_label=element_label,
        screen_number=int(screen_number_text) if screen_number_text else None,
    )


def clamp_point_to_screenshot(
    coordinate: tuple[int, int], screenshot_size: tuple[int, int]
) -> tuple[float, float]:
    """Clamps an untrusted model coordinate into the screenshot pixel space."""
    screenshot_width, screenshot_height = screenshot_size
    clamped_x = max(0, min(coordinate[0], screenshot_width))
    clamped_y = max(0, min(coordinate[1], screenshot_height))
    return clamped_x, clamped_y


def map_screenshot_point_to_global_logical_point(
    screenshot_point: tuple[float, float],
    screenshot_size_px: tuple[int, int],
    display_size_physical_px: tuple[int, int],
    display_device_pixel_ratio: float,
    display_frame_logical: tuple[float, float],
) -> tuple[float, float]:
    """Maps a point in the screenshot's pixel space to a global point in Qt
    logical (device-independent) coordinates.

    Two scales are applied, in this order:
    1. Screenshot pixels -> display physical pixels (the screenshot was
       downscaled to <=1280 px on its long edge before being sent to Claude).
    2. Display physical pixels -> logical points (divide by the screen's
       devicePixelRatio), then offset by the display's top-left logical
       origin inside the virtual desktop.
    """
    screenshot_width, screenshot_height = screenshot_size_px
    physical_width, physical_height = display_size_physical_px
    display_origin_x, display_origin_y = display_frame_logical

    scale_x = physical_width / screenshot_width
    scale_y = physical_height / screenshot_height

    device_pixel_x = screenshot_point[0] * scale_x
    device_pixel_y = screenshot_point[1] * scale_y

    logical_x = display_origin_x + device_pixel_x / display_device_pixel_ratio
    logical_y = display_origin_y + device_pixel_y / display_device_pixel_ratio
    return logical_x, logical_y


def quadratic_bezier_point(
    start_point: tuple[float, float],
    control_point: tuple[float, float],
    end_point: tuple[float, float],
    param_t: float,
) -> tuple[float, float]:
    """Quadratic bezier: B(t) = (1-t)²·P0 + 2(1-t)t·P1 + t²·P2.
    Same curve formula the Swift OverlayWindow uses for flight arcs."""
    param_t = max(0.0, min(param_t, 1.0))
    one_minus_t = 1.0 - param_t
    bezier_x = (
        one_minus_t * one_minus_t * start_point[0]
        + 2.0 * one_minus_t * param_t * control_point[0]
        + param_t * param_t * end_point[0]
    )
    bezier_y = (
        one_minus_t * one_minus_t * start_point[1]
        + 2.0 * one_minus_t * param_t * control_point[1]
        + param_t * param_t * end_point[1]
    )
    return bezier_x, bezier_y


def quadratic_bezier_tangent_degrees(
    start_point: tuple[float, float],
    control_point: tuple[float, float],
    end_point: tuple[float, float],
    param_t: float,
) -> float:
    """Heading of the curve at param_t in degrees (cartesian, y-down like Qt).
    Mirrors the Swift tangent: B'(t) = 2(1-t)(P1-P0) + 2t(P2-P1), rotated +90°
    so the triangle's tip (drawn pointing up) follows the direction of flight."""
    param_t = max(0.0, min(param_t, 1.0))
    one_minus_t = 1.0 - param_t
    tangent_x = (
        2 * one_minus_t * (control_point[0] - start_point[0])
        + 2 * param_t * (end_point[0] - control_point[0])
    )
    tangent_y = (
        2 * one_minus_t * (control_point[1] - start_point[1])
        + 2 * param_t * (end_point[1] - control_point[1])
    )
    return atan2_degrees(tangent_x, tangent_y)


def atan2_degrees(x_component: float, y_component: float) -> float:
    import math

    return math.atan2(y_component, x_component) * (180.0 / math.pi) + 90.0


def flight_control_point(
    start_point: tuple[float, float], end_point: tuple[float, float]
) -> tuple[float, float]:
    """Control point for the quadratic arc: the midpoint lifted upward so the
    buddy hops over the UI instead of sliding along a straight line. Lift
    scales with distance so short hops stay subtle."""
    midpoint_x = (start_point[0] + end_point[0]) / 2.0
    midpoint_y = (start_point[1] + end_point[1]) / 2.0
    horizontal_distance = abs(end_point[0] - start_point[0]) + abs(end_point[1] - start_point[1])
    arc_lift = min(90.0, 28.0 + horizontal_distance * 0.12)
    return midpoint_x, min(start_point[1], end_point[1]) - arc_lift


def flight_duration_seconds(
    start_point: tuple[float, float], end_point: tuple[float, float]
) -> float:
    """Distance-based flight time; short hops are quick, long flights wind down
    so the arrival never feels abrupt."""
    horizontal_distance = abs(end_point[0] - start_point[0]) + abs(end_point[1] - start_point[1])
    return max(0.4, min(0.85, 0.4 + horizontal_distance * 0.0015))
