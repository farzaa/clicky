using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using NAudio.Wave;

namespace Clicky.Services;

/// <summary>
/// Port of <c>ElevenLabsTTSClient.swift</c>. Posts the caption text to the
/// Worker's <c>/tts</c> route, receives an MP3 stream, and plays it through
/// the default output device via NAudio. Only one utterance plays at a
/// time — a new call cancels the previous playback.
/// </summary>
public sealed class ElevenLabsTtsClient : IDisposable
{
    private const string ElevenLabsModel = "eleven_flash_v2_5";
    private const double VoiceStability = 0.5;
    private const double VoiceSimilarityBoost = 0.75;

    private readonly HttpClient _httpClient;
    private readonly bool _ownsHttpClient;

    private readonly object _playbackLock = new();
    private WaveOutEvent? _activeWaveOut;
    private Mp3FileReader? _activeMp3Reader;
    private MemoryStream? _activeMp3Stream;

    public event EventHandler? PlaybackFinished;

    public bool IsPlaying
    {
        get
        {
            lock (_playbackLock)
            {
                return _activeWaveOut?.PlaybackState == PlaybackState.Playing;
            }
        }
    }

    public ElevenLabsTtsClient(HttpClient? httpClient = null)
    {
        if (httpClient is null)
        {
            _httpClient = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
            _ownsHttpClient = true;
        }
        else
        {
            _httpClient = httpClient;
            _ownsHttpClient = false;
        }
    }

    public async Task SpeakAsync(string caption, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(caption)) return;

        var requestPayload = JsonSerializer.Serialize(new
        {
            text = caption,
            model_id = ElevenLabsModel,
            voice_settings = new
            {
                stability = VoiceStability,
                similarity_boost = VoiceSimilarityBoost,
            },
        });

        using var requestMessage = new HttpRequestMessage(HttpMethod.Post, WorkerConfig.TtsUrl)
        {
            Content = new StringContent(requestPayload, Encoding.UTF8, "application/json"),
        };

        using var responseMessage = await _httpClient
            .SendAsync(requestMessage, cancellationToken)
            .ConfigureAwait(false);

        if (!responseMessage.IsSuccessStatusCode)
        {
            var errorBody = await responseMessage.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            throw new HttpRequestException(
                $"ElevenLabs proxy returned {(int)responseMessage.StatusCode}: {errorBody}");
        }

        var mp3Bytes = await responseMessage.Content.ReadAsByteArrayAsync(cancellationToken).ConfigureAwait(false);
        StartPlayback(mp3Bytes);
    }

    public void StopPlayback()
    {
        lock (_playbackLock)
        {
            TeardownCurrentPlaybackLocked();
        }
    }

    private void StartPlayback(byte[] mp3Bytes)
    {
        lock (_playbackLock)
        {
            TeardownCurrentPlaybackLocked();

            // Ownership of these disposables transfers to the field until
            // PlaybackStopped fires — the stream must outlive the reader.
            var mp3Stream = new MemoryStream(mp3Bytes, writable: false);
            var mp3Reader = new Mp3FileReader(mp3Stream);
            var waveOut = new WaveOutEvent();
            waveOut.Init(mp3Reader);

            waveOut.PlaybackStopped += OnWaveOutPlaybackStopped;

            _activeMp3Stream = mp3Stream;
            _activeMp3Reader = mp3Reader;
            _activeWaveOut = waveOut;

            waveOut.Play();
        }
    }

    private void OnWaveOutPlaybackStopped(object? sender, StoppedEventArgs stoppedEventArgs)
    {
        lock (_playbackLock)
        {
            TeardownCurrentPlaybackLocked();
        }
        PlaybackFinished?.Invoke(this, EventArgs.Empty);
    }

    private void TeardownCurrentPlaybackLocked()
    {
        if (_activeWaveOut is not null)
        {
            _activeWaveOut.PlaybackStopped -= OnWaveOutPlaybackStopped;
            try { _activeWaveOut.Stop(); } catch { /* already stopped */ }
            _activeWaveOut.Dispose();
            _activeWaveOut = null;
        }
        _activeMp3Reader?.Dispose();
        _activeMp3Reader = null;
        _activeMp3Stream?.Dispose();
        _activeMp3Stream = null;
    }

    public void Dispose()
    {
        StopPlayback();
        if (_ownsHttpClient) _httpClient.Dispose();
    }
}
