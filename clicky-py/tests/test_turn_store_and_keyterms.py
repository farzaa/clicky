"""Tests for the AssemblyAI turn bookkeeping, keyterm building, and the
audio power smoothing — all direct ports of Swift behavior."""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from clickpy.audio_conversion import smooth_audio_power_level  # noqa: E402
from clickpy.transcription import (  # noqa: E402
    AssemblyAITurnTranscriptStore,
    build_transcription_keyterms,
)


def test_turn_store_composes_active_and_committed_turns():
    store = AssemblyAITurnTranscriptStore()
    _changed, transcript = store.handle_turn_message(
        {"turn_order": 0, "transcript": "how do", "end_of_turn": False,
         "turn_is_formatted": False}
    )
    assert transcript == "how do"  # live in-flight turn reports text

    _changed, transcript = store.handle_turn_message(
        {"turn_order": 0, "transcript": "how do i commit", "end_of_turn": True,
         "turn_is_formatted": True}
    )
    assert transcript == "how do i commit"  # committed turn wins
    assert store.best_available_transcript_text() == "how do i commit"


def test_turn_store_formatted_beats_unformatted_on_same_order():
    store = AssemblyAITurnTranscriptStore()
    store.handle_turn_message(
        {"turn_order": 2, "transcript": "raw lowercase txt", "end_of_turn": True,
         "turn_is_formatted": False}
    )
    store.handle_turn_message(  # same order arrives formatted later
        {"turn_order": 2, "transcript": "Raw lower case txt", "end_of_turn": False,
         "turn_is_formatted": True}
    )
    _changed, transcript = store.handle_turn_message(
        {"turn_order": 3, "transcript": "next question", "end_of_turn": True,
         "turn_is_formatted": True}
    )
    assert transcript == "Raw lower case txt next question"


def test_turn_store_unformatted_miss_keeps_formatted():
    store = AssemblyAITurnTranscriptStore()
    store.handle_turn_message(
        {"turn_order": 0, "transcript": "Formatted text", "end_of_turn": True,
         "turn_is_formatted": True}
    )
    # A stale unformatted echo must not downgrade the stored formatted turn
    store.handle_turn_message(
        {"turn_order": 0, "transcript": "old formatted", "end_of_turn": True,
         "turn_is_formatted": False}
    )
    assert store.compose_full_transcript() == "Formatted text"


def test_turn_store_preserves_ordering_by_turn_order():
    store = AssemblyAITurnTranscriptStore()
    for turn_order, text in [(3, "third"), (1, "first"), (2, "second")]:
        store.handle_turn_message(
            {"turn_order": turn_order, "transcript": text, "end_of_turn": True,
             "turn_is_formatted": True}
        )
    assert store.compose_full_transcript() == "first second third"


def test_turn_store_missing_turn_order_follows_active():
    store = AssemblyAITurnTranscriptStore()
    uncommitted = {"transcript": "partial", "end_of_turn": False,
                   "turn_is_formatted": False}
    store.handle_turn_message({**uncommitted, "turn_order": 5})
    # A later event without turn_order continues the active turn's stream
    _changed, transcript = store.handle_turn_message(
        {**uncommitted, "transcript": "partial phase"}
    )
    assert transcript == "partial phase"
    assert store._active_turn_order == 5


def test_turn_store_empty_transcripts_never_store():
    store = AssemblyAITurnTranscriptStore()
    store.handle_turn_message(
        {"turn_order": 0, "transcript": "", "end_of_turn": True,
         "turn_is_formatted": True}
    )
    assert store.compose_full_transcript() == ""


def test_turn_store_latest_text_fallback():
    store = AssemblyAITurnTranscriptStore()
    store.handle_turn_message(
        {"transcript": "words", "end_of_turn": False, "turn_is_formatted": False}
    )
    # An empty commit clears the active turn; with nothing stored, the best
    # available text still reports the last known words (Swift's
    # latestTranscriptText fallback).
    store.handle_turn_message(
        {"transcript": "", "end_of_turn": True, "turn_is_formatted": True}
    )
    assert store.best_available_transcript_text() == "words"


def test_keyterms_base_list_first_appearance_wins():
    keyterms = build_transcription_keyterms([])
    assert keyterms[0] == "makesomething"
    assert keyterms == [
        "makesomething", "Learning Buddy", "Codex", "Claude", "Anthropic",
        "OpenAI", "SwiftUI", "Xcode", "Vercel", "Next.js", "localhost",
    ]


def test_keyterms_contextual_and_dedup_case_insensitive():
    keyterms = build_transcription_keyterms(
        ["CLAUDE", " claude ", "element pointing", ""]
    )
    # "CLAUDE" dedupes against base "Claude" (same lowercase), debut of
    # "element pointing" appended, blank dropped
    assert keyterms == [
        "makesomething", "Learning Buddy", "Codex", "Claude", "Anthropic",
        "OpenAI", "SwiftUI", "Xcode", "Vercel", "Next.js", "localhost",
        "element pointing",
    ]


def test_power_level_smoothing_decay_floor():
    # Landscape like Swift: falls slowly between spikes instead of zeroing
    assert smooth_audio_power_level(0.6, 0.0) == 0.6  # note picks up
    assert smooth_audio_power_level(0.0, 0.6) == 0.6 * 0.72  # decay, not zero
    assert smooth_audio_power_level(0.2, 0.9) == 0.9 * 0.72  # previous wins
