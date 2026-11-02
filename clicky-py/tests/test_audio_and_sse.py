"""Tests for the audio conversion helpers (ports of BuddyAudioConversionSupport
behavior) and the Claude SSE parser."""

import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from clickpy.audio_conversion import PCM16AudioConverter, WAVFileBuilder  # noqa: E402
from clickpy.claude_api import ClaudeAPI  # noqa: E402


def test_wav_header_matches_riff_layout():
    pcm = b"\x01\x00\x02\x00\x03\x00\x04\x00"  # 4 frames of PCM16
    wav = WAVFileBuilder.build_wav_data(pcm, sample_rate=16_000)
    assert wav[:4] == b"RIFF"
    riff_size = struct.unpack("<I", wav[4:8])[0]
    assert riff_size == 36 + 8
    assert wav[8:12] == b"WAVE"
    assert wav[12:16] == b"fmt "
    assert wav[16:20] == b"\x10\x00\x00\x00"  # 16-byte fmt chunk
    assert struct.unpack("<H", wav[20:22])[0] == 1  # PCM tag
    assert struct.unpack("<H", wav[22:24])[0] == 1  # mono
    assert struct.unpack("<I", wav[24:28])[0] == 16_000
    assert struct.unpack("<I", wav[28:32])[0] == 32_000  # byte rate
    assert struct.unpack("<H", wav[32:34])[0] == 2  # block align
    assert struct.unpack("<H", wav[34:36])[0] == 16  # bits
    assert wav[36:40] == b"data"
    assert struct.unpack("<I", wav[40:44])[0] == 8
    assert wav[44:] == pcm


def test_converter_resamples_and_clips():
    converter = PCM16AudioConverter(target_sample_rate=16_000)
    converter.session_source_format_changed(48_000)
    # 480 samples (10 ms) of a 250Hz sine at full scale
    import numpy

    samples = numpy.sin(numpy.linspace(0.0, 250 * 2 * numpy.pi, 480)).astype(numpy.float32)
    pcm16 = converter.convert_to_pcm16_bytes(samples.tobytes())
    frame_count = len(pcm16) // 2  # int16 mono
    assert frame_count == 160  # 10 ms at 16 kHz


def test_converter_clips_overflow():
    import numpy

    converter = PCM16AudioConverter(target_sample_rate=16_000)
    converter.session_source_format_changed(16_000)
    loud = (numpy.ones(100) * 4.0).astype(numpy.float32)
    pcm16 = converter.convert_to_pcm16_bytes(loud.tobytes())
    int16_samples = numpy.frombuffer(pcm16, dtype=numpy.int16)
    assert int16_samples.max() == 32_767


class _FakeStreamingResponse:
    """Mimics the httpx streaming response's iter_lines for SSE parsing."""

    def __init__(self, lines):
        self._lines = lines

    def iter_lines(self):
        return iter(self._lines)


def test_sse_parser_accumulates_text_deltas():
    lines = [
        'data: {"type":"message_start"}',
        "data: [NOT JSON]",
        'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hello "}}',
        'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"world"}}',
        'data: {"type":"message_stop"}',
    ]
    seen = []

    def on_text_chunk(accumulated):
        seen.append(accumulated)

    accumulated = ClaudeAPI._consume_sse_stream(_FakeStreamingResponse(lines), on_text_chunk)
    assert accumulated == "hello world"
    assert seen == ["hello ", "hello world"]


def test_sse_stops_on_done_marker():
    lines = [
        'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"abc"}}',
        "data: [DONE]",
        'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"NEVER"}}',
    ]
    accumulated = ClaudeAPI._consume_sse_stream(_FakeStreamingResponse(lines), None)
    assert accumulated == "abc"


def test_media_type_detection():
    from clickpy.claude_api import detect_image_media_type

    assert detect_image_media_type(b"\x89\x50\x4e\x47\x0d\x0a\x1a\x0a...") == "image/png"
    assert detect_image_media_type(b"\xff\xd8\xff\xe0jpeg") == "image/jpeg"
