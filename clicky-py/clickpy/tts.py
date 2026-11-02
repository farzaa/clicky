"""ElevenLabs TTS client — port of ElevenLabsTTSClient.swift.

Sends text to the Worker proxy and plays the resulting mp3 through the
system audio output via QMediaPlayer (AVAudioPlayer's counterpart on
Windows). Exposes isPlaying for the transient-cursor scheduling, and the
playback-finished signal arrives as a Qt signal so the overlay can react.
"""

from __future__ import annotations

import os
import tempfile

from PySide6.QtCore import QObject, QUrl, Signal
from PySide6.QtMultimedia import QAudioOutput, QMediaPlayer


class ElevenLabsTTSClient(QObject):
    # Emitted when the current mp3 finishes playing (QMediaPlayer's state change)
    playbackFinished = Signal()
    # Emitted when playback actually starts — the state machine switches from
    # "processing" to "responding" at this moment, like the Swift comment says.
    playbackStarted = Signal()

    def __init__(self, proxy_url: str, parent: QObject | None = None):
        super().__init__(parent)
        self.proxy_url = proxy_url
        self.audio_player = QMediaPlayer(self)
        self.audio_output = QAudioOutput(self)
        self.audio_player.setAudioOutput(self.audio_output)
        self.audio_output.setVolume(1.0)
        self.audio_player.playbackStateChanged.connect(self._on_playback_state_changed)
        self._active_temp_file_path: str | None = None

    def _on_playback_state_changed(self, new_state):
        from PySide6.QtMultimedia import QMediaPlayer

        if new_state == QMediaPlayer.PlaybackState.PlayingState:
            self.playbackStarted.emit()
        elif new_state == QMediaPlayer.PlaybackState.StoppedState:
            self._delete_previous_temp_file()
            self.playbackFinished.emit()

    def _delete_previous_temp_file(self):
        # The temp mp3 must outlive the track; only delete after playback stops.
        if self._active_temp_file_path is None:
            return
        try:
            os.remove(self._active_temp_file_path)
        except OSError:
            pass
        self._active_temp_file_path = None

    def speak_text(self, text: str) -> None:
        """Sends text to the TTS proxy and plays the audio. Blocks for the
        network download (run on a worker thread) but returns as soon as
        playback has or has-waited reached the point of playing."""
        import httpx

        body = {
            "text": text,
            "model_id": "eleven_flash_v2_5",
            "voice_settings": {
                "stability": 0.5,
                "similarity_boost": 0.75,
            },
        }

        response = httpx.post(
            self.proxy_url,
            headers={"content-type": "application/json", "Accept": "audio/mpeg"},
            json=body,
            timeout=30.0,
        )
        if not (200 <= response.status_code < 300):
            raise RuntimeError(
                f"TTS API error ({response.status_code}): {response.text}"
            )

        audio_data = response.content
        if not audio_data:
            raise RuntimeError("TTS proxy returned no audio.")

        # QMediaPlayer needs a filesystem URL (memory-backed QMediaContent
        # support is patchy on Windows), so park the mp3 in a temp file that
        # we clean up when playback stops.
        fd, temp_file_path = tempfile.mkstemp(suffix=".mp3", prefix="clicky-tts-")
        with os.fdopen(fd, "wb") as mp3_file:
            mp3_file.write(audio_data)
        self._active_temp_file_path = temp_file_path

        print(f"🔊 ElevenLabs TTS: playing {len(audio_data) // 1024}KB audio")
        self.audio_player.setSource(QUrl.fromLocalFile(temp_file_path))
        self.audio_player.play()

    @property
    def is_playing(self) -> bool:
        from PySide6.QtMultimedia import QMediaPlayer

        return self.audio_player.playbackState() == QMediaPlayer.PlaybackState.PlayingState

    def stop_playback(self) -> None:
        """Stops any in-progress playback immediately."""
        self.audio_player.stop()
