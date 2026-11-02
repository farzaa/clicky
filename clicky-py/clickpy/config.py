"""Settings for the Python Clicky port.

Mirrors the Swift app's persisted preferences (selectedClaudeModel,
isClickyCursorEnabled) stored in a JSON file instead of UserDefaults, plus
the proxy base URL. The proxy holds all API keys — like the macOS app, no
key ever lives in this app.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, asdict
from pathlib import Path


def default_settings_directory() -> Path:
    """%APPDATA% on Windows (created if missing); falls back to ~/.clicky-py
    on platforms without APPDATA."""
    appdata_directory = os.environ.get("APPDATA")
    if appdata_directory:
        return Path(appdata_directory) / "ClickyPy"
    return Path.home() / ".clicky-py"


@dataclass
class CompanionSettings:
    # Base URL of the Cloudflare Worker proxy (or any local worker instance).
    # The macOS app hardcodes a placeholder workers.dev URL; on Windows the
    # common case is running `wrangler dev` locally, so default there.
    proxy_base_url: str = "http://127.0.0.1:8787"
    # Claude model used for voice responses. Named exactly like the Swift
    # value so both apps read/write the same model identifiers.
    selected_model: str = "claude-sonnet-4-6"
    # Whether the blue cursor overlay is always visible. When off, the cursor
    # only appears transiently during an interaction (transient cursor mode).
    is_clicky_cursor_enabled: bool = True
    # Push-to-talk key combination. ctrl+option on macOS; ctrl+alt is the
    # direct Windows equivalent.
    push_to_talk_hold_keys: tuple[str, ...] = ("ctrl", "alt")
    # Which vision/chat backend answers: "claude" (Worker proxy) or "openai"
    # (direct, OPENAI_API_KEY from the environment).
    selected_chat_backend: str = "claude"
    available_models_claude: tuple[str, ...] = ("claude-sonnet-4-6", "claude-opus-4-6")
    # Extra transcription keyterms fed to the provider (bias recognition)
    contextual_keyterms: tuple[str, ...] = ()
    # Show the tray balloon hint exactly once on first run
    has_seen_first_run_hint: bool = False

    @classmethod
    def load(cls) -> "CompanionSettings":
        settings_path = default_settings_directory() / "settings.json"
        try:
            stored_values = json.loads(settings_path.read_text(encoding="utf-8"))
            settings = cls()
            known_field_names = {field.name for field in cls.__dataclass_fields__.values()}
            for key, value in stored_values.items():
                if key in known_field_names:
                    # Tuples arrive as lists from JSON
                    current_value = getattr(settings, key)
                    if isinstance(current_value, tuple) and isinstance(value, list):
                        value = tuple(value)
                    setattr(settings, key, value)
            return settings
        except (FileNotFoundError, json.JSONDecodeError, TypeError):
            return cls()

    def save(self) -> None:
        settings_path = default_settings_directory() / "settings.json"
        settings_path.parent.mkdir(parents=True, exist_ok=True)
        settings_path.write_text(
            json.dumps(asdict(self), indent=2), encoding="utf-8"
        )
