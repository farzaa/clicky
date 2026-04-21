using NAudio.Wave;

namespace Clicky.Services;

/// <summary>
/// Captures the default input device as 16-kHz, 16-bit, mono PCM — the
/// exact format AssemblyAI's realtime endpoint expects. This is the
/// Windows equivalent of <c>AVAudioEngine.inputNode.installTap</c> in the
/// macOS <c>BuddyDictationManager</c>.
///
/// Uses <see cref="WaveInEvent"/> (winmm wrapper) because it can ask the
/// Windows audio engine for a specific format directly — shared-mode
/// conversion to 16 kHz mono happens in the mixer so we don't need to
/// pull in MediaFoundation for resampling.
/// </summary>
public sealed class MicrophoneCaptureService : IDisposable
{
    private const int TargetSampleRateHz = 16_000;
    private const int TargetBitsPerSample = 16;
    private const int TargetChannelCount = 1;

    // 100 ms of 16-kHz 16-bit mono = 3,200 bytes per buffer. AssemblyAI
    // accepts 50–1000 ms frames; 100 ms gives snappy partials without
    // drowning the websocket in tiny frames.
    private const int BufferMilliseconds = 100;

    private WaveInEvent? _waveInDevice;

    public event EventHandler<ReadOnlyMemory<byte>>? AudioFrameCaptured;
    public event EventHandler<Exception>? CaptureFaulted;

    public bool IsRunning { get; private set; }

    public void Start()
    {
        if (IsRunning) return;

        _waveInDevice = new WaveInEvent
        {
            WaveFormat = new WaveFormat(TargetSampleRateHz, TargetBitsPerSample, TargetChannelCount),
            BufferMilliseconds = BufferMilliseconds,
            // Three queued buffers keeps the capture pipeline saturated
            // without introducing perceptible latency.
            NumberOfBuffers = 3,
        };

        _waveInDevice.DataAvailable += OnMicrophoneDataAvailable;
        _waveInDevice.RecordingStopped += OnMicrophoneRecordingStopped;

        _waveInDevice.StartRecording();
        IsRunning = true;
    }

    public void Stop()
    {
        if (!IsRunning) return;
        IsRunning = false;

        try
        {
            _waveInDevice?.StopRecording();
        }
        catch
        {
            // StopRecording throws if the device was already released —
            // swallow; the consumer has no action to take.
        }
    }

    private void OnMicrophoneDataAvailable(object? sender, WaveInEventArgs waveInEventArgs)
    {
        if (waveInEventArgs.BytesRecorded <= 0) return;
        // Copy into a fresh buffer — NAudio reuses the internal one across
        // events, so consumers (channels, async sends) must own their slice.
        var frameCopy = new byte[waveInEventArgs.BytesRecorded];
        Buffer.BlockCopy(waveInEventArgs.Buffer, 0, frameCopy, 0, waveInEventArgs.BytesRecorded);
        AudioFrameCaptured?.Invoke(this, frameCopy);
    }

    private void OnMicrophoneRecordingStopped(object? sender, StoppedEventArgs stoppedEventArgs)
    {
        if (stoppedEventArgs.Exception is not null)
        {
            CaptureFaulted?.Invoke(this, stoppedEventArgs.Exception);
        }

        if (_waveInDevice is not null)
        {
            _waveInDevice.DataAvailable -= OnMicrophoneDataAvailable;
            _waveInDevice.RecordingStopped -= OnMicrophoneRecordingStopped;
            _waveInDevice.Dispose();
            _waveInDevice = null;
        }
    }

    public void Dispose()
    {
        Stop();
    }
}
