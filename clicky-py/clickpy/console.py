"""Console safety for emoji-style logging on Windows.

The Swift codebase logs with emoji prefixes, and the port keeps that style
for cross-referencing — but Windows consoles often run cp1252, where any
emoji print raises UnicodeEncodeError. Reconfigure stdout/stderr to UTF-8
with replacement as the first thing the app does.
"""

from __future__ import annotations

import sys


def configure_unicode_console() -> None:
    for console_stream in (sys.stdout, sys.stderr):
        if console_stream is not None and hasattr(console_stream, "reconfigure"):
            console_stream.reconfigure(encoding="utf-8", errors="replace")
