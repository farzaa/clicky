"""Device smoke check — runs against real hardware (no GUI): probes PortAudio
audio devices, the pynput keyboard hook, and optional SAPI availability.
Informational: exits 0 unless a required layer is broken.

    .\\.venv\\Scripts\\python.exe scripts\\smoke_devices.py
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from clickpy.console import configure_unicode_console  # noqa: E402

configure_unicode_console()


def check_audio_devices() -> bool:
    import sounddevice

    devices = sounddevice.query_devices()
    input_devices = [
        (index, device["name"], device["max_input_channels"])
        for index, device in enumerate(devices)
        if device.get("max_input_channels", 0) > 0
    ]
    default_input = sounddevice.default.device[0]

    print(f"audio: PortAudio host API: {sounddevice.query_hostapis()[0]['name']}")
    print(f"audio: {len(input_devices)} input device(s)")
    for index, name, channels in input_devices[:5]:
        marker = " <- default" if index == default_input else ""
        print(f"audio:   [{index}] {name} ({channels} in){marker}")
    return len(input_devices) > 0


def check_keyboard_hook() -> bool:
    from pynput import keyboard as pynput_keyboard

    listener = pynput_keyboard.Listener()
    listener.start()
    listener_stop_ok = listener.is_alive()
    listener.stop()
    listener.join(timeout=2.0)
    print(f"keyboard: global hook listener started/stopped ok (alive while on: {listener_stop_ok})")
    return listener_stop_ok


def check_sapi_fallback() -> bool:
    """Optional layer: Windows SAPI used by the credits-error fallback."""
    try:
        import win32com.client  # noqa: F401

        print("sapi: pywin32 available (TTS error fallback works)")
        return True
    except ImportError:
        print("sapi: pywin32 NOT installed (error fallback silent) — optional")
        return False


def main() -> int:
    print("clicky-py device smoke")
    print("=" * 40)
    audio_ok = check_audio_devices()
    keyboard_ok = check_keyboard_hook()
    check_sapi_fallback()
    print("=" * 40)

    problems = []
    if not audio_ok:
        problems.append("no audio input device found")
    if not keyboard_ok:
        problems.append("pynput keyboard hook failed to start")
    if problems:
        print("PROBLEMS: " + "; ".join(problems))
        return 1
    print("device smoke ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
