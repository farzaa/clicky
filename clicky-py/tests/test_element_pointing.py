"""Tests for [POINT:...] parsing and coordinate math — ports of the cases the
Swift CompanionManager.parsePointingCoordinates must keep passing."""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from clickpy.element_pointing import (  # noqa: E402
    clamp_point_to_screenshot,
    flight_control_point,
    map_screenshot_point_to_global_logical_point,
    parse_pointing_coordinates,
    quadratic_bezier_point,
)


def test_no_tag_at_all():
    result = parse_pointing_coordinates("hello, your request is on its way")
    assert result.spoken_text == "hello, your request is on its way"
    assert result.coordinate is None
    assert result.element_label is None
    assert result.screen_number is None


def test_point_none():
    result = parse_pointing_coordinates(
        "html stands for hypertext markup language, it's basically the skeleton of every web page. [POINT:none]"
    )
    assert result.spoken_text == (
        "html stands for hypertext markup language, it's basically the skeleton of every web page."
    )
    assert result.coordinate is None


def test_point_coordinate_with_label():
    result = parse_pointing_coordinates(
        "open the color inspector in the top right toolbar. [POINT:1100,42:color inspector]"
    )
    assert result.spoken_text == "open the color inspector in the top right toolbar."
    assert result.coordinate == (1100, 42)
    assert result.element_label == "color inspector"
    assert result.screen_number is None


def test_point_coordinate_with_label_and_screen_number():
    result = parse_pointing_coordinates(
        "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    )
    assert result.coordinate == (400, 300)
    assert result.element_label == "terminal"
    assert result.screen_number == 2


def test_point_coordinate_without_label():
    # Grammar allows omitting the label entirely
    result = parse_pointing_coordinates("check that menu. [POINT:285,11]")
    assert result.coordinate == (285, 11)
    assert result.element_label is None


def test_tag_must_be_at_the_end():
    # A tag mid-sentence is NOT stripped
    result = parse_pointing_coordinates("[POINT:5,5:x] and then more text")
    assert result.coordinate is None
    assert result.spoken_text.startswith("[POINT:")


def test_clampOutOfRange():
    assert clamp_point_to_screenshot((1500, 900), (1280, 800)) == (1280, 800)
    assert clamp_point_to_screenshot((-5, 10), (1280, 800)) == (0, 10)


def test_coordinate_mapping_single_monitor_dpr_one():
    # 1280x800 screenshot on a 1280x800 display at scale 1 — identity + offset
    logical = map_screenshot_point_to_global_logical_point(
        screenshot_point=(640, 400),
        screenshot_size_px=(1280, 800),
        display_size_physical_px=(1280, 800),
        display_device_pixel_ratio=1.0,
        display_frame_logical=(0, 0),
    )
    assert logical == (640, 400)


def test_coordinate_mapping_with_downscaled_screenshot_and_dpi_two():
    # Screenshot was downscaled to 1280-wide on a 2560-wide display with dpr 2
    # (so the display is 1280 logical points): scale factor is 2.0 physical px
    # per screenshot px, /2 back to logical -> exact identity again.
    logical = map_screenshot_point_to_global_logical_point(
        screenshot_point=(640, 400),
        screenshot_size_px=(1280, 800),
        display_size_physical_px=(2560, 1600),
        display_device_pixel_ratio=2.0,
        display_frame_logical=(0, 0),
    )
    assert logical == (640, 400)


def test_coordinate_mapping_secondary_monitor_negative_origin():
    # Monitor left of the primary screen: logical origin x = -1920
    logical = map_screenshot_point_to_global_logical_point(
        screenshot_point=(100, 100),
        screenshot_size_px=(1280, 800),
        display_size_physical_px=(1920, 1200),
        display_device_pixel_ratio=1.0,
        display_frame_logical=(-1920, 40),
    )
    assert logical == (-1920 + 100 * (1920 / 1280), 40 + 100 * (1200 / 800))


def test_bezier_midpoint_matches_quadratic_math():
    p0, p1, p2 = (0.0, 0.0), (50.0, -50.0), (100.0, 0.0)
    # At t=0.5 a quadratic bezier evaluates to (P0/4 + P1/2 + P2/4)
    mid = quadratic_bezier_point(p0, p1, p2, 0.5)
    assert abs(mid[0] - 50.0) < 1e-6
    assert abs(mid[1] - (-25.0)) < 1e-6


def test_flight_control_point_lifts_upward():
    control = flight_control_point((100, 500), (800, 500))
    assert control[1] < 500  # arc lifts above both endpoints
    assert control[0] == 450.0  # centered between them
