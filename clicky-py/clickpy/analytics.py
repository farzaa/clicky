"""Optional PostHog analytics — port of ClickyAnalytics.swift.

Kept as a stub: PostHog is only enabled when CLICKY_PY_POSTHOG_KEY is set,
so the port never phones home accidentally. Event names match the Swift
integrations so dashboards could unify across both.
"""

from __future__ import annotations

import os
from datetime import datetime, timezone


class ClickyAnalytics:
    def __init__(self):
        self._posthog_client = None
        api_key = os.environ.get("CLICKY_PY_POSTHOG_KEY")
        if api_key:
            try:
                from posthog import Posthog

                self._posthog_client = Posthog(
                    api_key, host="https://us.i.posthog.com"
                )
            except ImportError:
                print("[analytics] posthog package not installed; analytics disabled")
        self._started_at = datetime.now(timezone.utc).isoformat()

    def _track_event(self, event_name: str, attributes: dict):
        if self._posthog_client is None:
            return
        self._posthog_client.capture(distinct_id="clicky-py-mac-user", event=event_name, properties=attributes)

    # Same events as the Swift file -------------------------------

    def track_companion_interaction_result(self, transcript: str, response: str):
        self._track_event(
            "companion_interaction",
            {"transcript": transcript, "response": response},
        )

    def push_to_talk_pressed(self):
        self._track_event("push_to_talk_pressed", {})

    def track_ai_response_received(self, response: str):
        self._track_event("ai_response_received", {"response": response})

    def track_element_pointed(self, element_label: str | None):
        self._track_event("element_pointed_at", {"element": element_label or "none"})

    def track_tts_error(self, error: str):
        self._track_event("tts_error", {"error": error})

    def track_response_error(self, error: str):
        self._track_event("response_error", {"error": error})

    def track_transcription_error(self, error: str):
        self._track_event("transcription_error", {"error": error})
