"""Design system tokens — ported from DesignSystem.swift.

Dark surfaces with the Tailwind blue accent, same hex values as the macOS
app so the port looks like Clicky. Qt code reads DS.* exactly like SwiftUI
reads it.
"""

from __future__ import annotations


class Colors:
    # Layered surfaces from deepest to most elevated.
    background = "#101211"
    surface1 = "#171918"
    surface2 = "#202221"
    surface3 = "#272A29"
    surface4 = "#2E3130"

    border_subtle = "#373B39"
    border_strong = "#444947"

    text_primary = "#ECEEED"
    text_secondary = "#ADB5B2"
    text_tertiary = "#6B736F"

    # Accent (Tailwind blue)
    accent = "#2563eb"
    accent_hover = "#1d4ed8"

    # The buddy cursor blue
    buddy_cursor = "#2f8cec"


class CornerRadius:
    small = 6
    medium = 10
    large = 16
    # Speech bubble / panel rounding
    panel = 14


class FontSizes:
    title = 18
    body = 14
    caption = 12
