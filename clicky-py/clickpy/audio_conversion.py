"""Shared audio conversion helpers for voice transcription providers.

Ports BuddyAudioConversionSupport.swift to numpy:
- PCM16AudioConverter: float32 mic buffers -> PCM16 mono 16-bit at 16 kHz
- WAVFileBuilder: PCM16 frames -> a WAV payload (used by upload providers)

The AVAudioConverter sample-rate conversion is replaced by linear
interpolation; linear resampling at 16 kHz from a 44.1/48 kHz mic feed is
adequate for a speech recognition websocket.
"""

from __future__ import annotations

import struct
from typing import Callable, Optional

import numpy


class PCM16AudioConverter:
    """Converts variable-rate float32 mono audio into PCM16 bytes at
    targetSampleRate. The resampler tracks the stream's absolute sample
    position so frame counts are exact across chunk boundaries (no chronic
    sample drift, unlike naive per-chunk floor() resampling)."""

    def __init__(self, target_sample_rate: int, on_audio_level: Optional[Callable[[float], None]] = None):
        self.target_sample_rate = target_sample_rate
        # Tracks the source sample rate so a changing device rate re-seeds state
        self._source_sample_rate: Optional[int] = None
        self._last_input_sample: Optional[float] = None
        # Absolute count of input samples consumed so far (source timeline)
        self._input_samples_consumed = 0
        # Optional RMS power callback (0..1) used by the waveform UI
        self._on_audio_level = on_audio_level

    def convert_to_pcm16_bytes(self, float32_buffer: bytes) -> bytes:
        """Converts one chunk of interleaved float32 mono audio to PCM16 bytes.
        The stream is continuous across calls."""
        import numpy

        float_samples: numpy.ndarray = numpy.frombuffer(float32_buffer, dtype=numpy.float32)
        if float_samples.size == 0:
            return b""

        # Waveform meters the mic feed before resampling
        power_level = self.compute_audio_power_level(float_samples)
        if self._on_audio_level is not None:
            self._on_audio_level(power_level)

        sample_rate = self._source_sample_rate
        if sample_rate is None:
            sample_rate = 48_000

        if sample_rate == self.target_sample_rate:
            resampled = float_samples
        else:
            resampled = self._resample(float_samples)

        if resampled.size == 0:
            return b""

        # Scale float [-1, 1] to int16 with clipping to avoid wraparound pops
        int16_samples = numpy.clip(resampled * 32767.0, -32768.0, 32767.0).astype(numpy.int16)
        return int16_samples.tobytes()

    def session_source_format_changed(self, source_sample_rate: int) -> None:
        """Notifies the converter that the mic stream restarted at a new rate."""
        if source_sample_rate != self._source_sample_rate:
            self._source_sample_rate = source_sample_rate
            self._reset_stream_position()

    def _reset_stream_position(self):
        self._last_input_sample = None
        self._input_samples_consumed = 0

    def _resample(self, float_samples) -> "numpy.ndarray":
        """Exact streaming linear interpolation.

        Every output frame m (counted across the whole stream) corresponds to
        the source position m * (source_rate / target_rate). Each chunk
        produces every output frame whose position falls inside this chunk's
        [base, base + N) window, where base is the chunk's absolute start.
        """
        import math

        import numpy

        source_rate = float(self._source_sample_rate)
        sample_rate_ratio = source_rate / float(self.target_sample_rate)  # source per output

        chunk_length = float_samples.size
        if self._last_input_sample is not None:
            # extended[0] is the previous chunk's last sample (source position
            # base - 1), so interpolation can span the boundary.
            extended = numpy.concatenate(([self._last_input_sample], float_samples))
            base = self._input_samples_consumed - 1
        else:
            extended = float_samples
            base = 0.0

        # Output frames m with source position in [base, base + N)
        first_output_frame = math.ceil(base / sample_rate_ratio)
        # Guard: if base/ratio is (exactly) an integer, ceil keeps it — pos
        # == base is allowed (interpolate at the boundary using prev sample).
        last_output_frame_exclusive = math.ceil((base + chunk_length) / sample_rate_ratio)
        if last_output_frame_exclusive <= first_output_frame:
            self._advance_state(float_samples, chunk_length)
            return numpy.empty(0, dtype=numpy.float32)

        output_frame_indices = numpy.arange(first_output_frame, last_output_frame_exclusive)
        output_positions = output_frame_indices * sample_rate_ratio

        left_index = numpy.floor(output_positions - base).astype(numpy.int64)
        fraction = output_positions - base - left_index
        right_index = left_index + 1

        # First chunk has no previous sample to its left; clamp the left edge
        # so position 0 uses sample 0 directly (fraction then reaches into the
        # next sample at most once).
        if self._last_input_sample is None:
            left_index = numpy.clip(left_index, 0, chunk_length - 1)
        else:
            left_index = numpy.clip(left_index, 0, chunk_length)
        right_index = numpy.clip(right_index, 0, chunk_length)

        resampled = extended[left_index] * (1.0 - fraction) + extended[right_index] * fraction

        self._advance_state(float_samples, chunk_length)
        return resampled.astype(numpy.float32)

    def _advance_state(self, float_samples, chunk_length: int):
        self._last_input_sample = float(float_samples[-1])
        self._input_samples_consumed += chunk_length

    @staticmethod
    def compute_audio_power_level(float_samples) -> float:
        """RMS power normalized to 0..1 for waveform visualization."""
        import numpy

        root_mean_square = float(numpy.sqrt(numpy.mean(float_samples * float_samples) + 1e-12))
        return max(0.0, min(1.0, root_mean_square * 3.0))


class WAVFileBuilder:
    """Builds a WAV file payload from PCM16 mono audio.

    Struct-laid out exactly like BuddyWAVFileBuilder.buildWAVData: 44-byte
    RIFF header little-endian + the raw PCM16 frames."""

    @staticmethod
    def build_wav_data(
        pcm16_audio_data: bytes,
        sample_rate: int,
        channel_count: int = 1,
        bits_per_sample: int = 16,
    ) -> bytes:
        byte_rate = sample_rate * channel_count * bits_per_sample // 8
        block_align = channel_count * bits_per_sample // 8
        data_chunk_size = len(pcm16_audio_data)
        riff_chunk_size = 36 + data_chunk_size

        header = b"".join(
            [
                b"RIFF",
                struct.pack("<I", riff_chunk_size),
                b"WAVE",
                b"fmt ",
                struct.pack("<I", 16),
                struct.pack("<H", 1),  # PCM format tag
                struct.pack("<H", channel_count),
                struct.pack("<I", sample_rate),
                struct.pack("<I", byte_rate),
                struct.pack("<H", block_align),
                struct.pack("<H", bits_per_sample),
                b"data",
                struct.pack("<I", data_chunk_size),
            ]
        )
        return header + pcm16_audio_data
