namespace Clicky.Services;

/// <summary>
/// Bridges <see cref="MicrophoneCaptureService"/> to
/// <see cref="AssemblyAIStreamingClient"/> and exposes a simple
/// start/finalize/stop API for the orchestrator. Equivalent role to the
/// macOS <c>BuddyDictationManager</c> — minus the Apple-speech fallback
/// since Windows only ships with AssemblyAI in M2.
/// </summary>
public sealed class DictationSession : IAsyncDisposable
{
    /// <summary>Fallback window — if AssemblyAI hasn't emitted a final
    /// transcript within this time after <see cref="RequestFinalTranscriptAsync"/>,
    /// the session resolves with whatever partial it last saw. Matches the
    /// 2.8 s fallback in the macOS provider.</summary>
    private static readonly TimeSpan FinalTranscriptFallback = TimeSpan.FromSeconds(2.8);

    private readonly MicrophoneCaptureService _microphoneCaptureService;
    private readonly AssemblyAIStreamingClient _assemblyAIStreamingClient;

    private string _latestPartialTranscript = string.Empty;
    private TaskCompletionSource<string>? _finalTranscriptCompletionSource;
    private CancellationTokenSource? _sessionLifetimeCts;

    public event EventHandler<string>? PartialTranscriptUpdated;
    public event EventHandler<Exception>? SessionFaulted;

    public bool IsActive { get; private set; }

    public DictationSession()
    {
        _microphoneCaptureService = new MicrophoneCaptureService();
        _assemblyAIStreamingClient = new AssemblyAIStreamingClient();
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        if (IsActive) return;

        _sessionLifetimeCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        _latestPartialTranscript = string.Empty;
        _finalTranscriptCompletionSource = null;

        _assemblyAIStreamingClient.TranscriptUpdated += OnAssemblyAITranscriptUpdated;
        _assemblyAIStreamingClient.FinalTranscriptReady += OnAssemblyAIFinalTranscriptReady;
        _assemblyAIStreamingClient.SessionFaulted += OnUpstreamSessionFaulted;

        _microphoneCaptureService.AudioFrameCaptured += OnMicrophoneAudioFrameCaptured;
        _microphoneCaptureService.CaptureFaulted += OnUpstreamSessionFaulted;

        // Open the websocket first — if this throws, the mic never starts.
        await _assemblyAIStreamingClient.StartAsync(_sessionLifetimeCts.Token).ConfigureAwait(false);
        _microphoneCaptureService.Start();

        IsActive = true;
    }

    /// <summary>
    /// Called on push-to-talk release. Stops the mic (so no more audio is
    /// sent), asks AssemblyAI to finalize the current turn, and awaits the
    /// final transcript — with a fallback to the last partial if the
    /// websocket doesn't echo a final within the grace window.
    /// </summary>
    public async Task<string> RequestFinalTranscriptAsync(CancellationToken cancellationToken)
    {
        if (!IsActive) return string.Empty;

        _microphoneCaptureService.Stop();

        _finalTranscriptCompletionSource = new TaskCompletionSource<string>(
            TaskCreationOptions.RunContinuationsAsynchronously);

        try
        {
            await _assemblyAIStreamingClient.RequestFinalTranscriptAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (Exception requestException)
        {
            SessionFaulted?.Invoke(this, requestException);
            return _latestPartialTranscript;
        }

        // Wait for FinalTranscriptReady or the fallback timer.
        using var fallbackCts = new CancellationTokenSource(FinalTranscriptFallback);
        using var registration = fallbackCts.Token.Register(() =>
            _finalTranscriptCompletionSource?.TrySetResult(_latestPartialTranscript));

        return await _finalTranscriptCompletionSource.Task.ConfigureAwait(false);
    }

    public async Task StopAsync(CancellationToken cancellationToken)
    {
        if (!IsActive) return;
        IsActive = false;

        _microphoneCaptureService.Stop();
        await _assemblyAIStreamingClient.StopAsync(cancellationToken).ConfigureAwait(false);

        _assemblyAIStreamingClient.TranscriptUpdated -= OnAssemblyAITranscriptUpdated;
        _assemblyAIStreamingClient.FinalTranscriptReady -= OnAssemblyAIFinalTranscriptReady;
        _assemblyAIStreamingClient.SessionFaulted -= OnUpstreamSessionFaulted;
        _microphoneCaptureService.AudioFrameCaptured -= OnMicrophoneAudioFrameCaptured;
        _microphoneCaptureService.CaptureFaulted -= OnUpstreamSessionFaulted;

        _sessionLifetimeCts?.Cancel();
        _sessionLifetimeCts?.Dispose();
        _sessionLifetimeCts = null;
    }

    private void OnMicrophoneAudioFrameCaptured(object? sender, ReadOnlyMemory<byte> frameBytes)
    {
        _assemblyAIStreamingClient.AppendAudio(frameBytes);
    }

    private void OnAssemblyAITranscriptUpdated(object? sender, TranscriptEventArgs args)
    {
        if (args.Transcript.Length > 0)
        {
            _latestPartialTranscript = args.Transcript;
        }
        PartialTranscriptUpdated?.Invoke(this, _latestPartialTranscript);
    }

    private void OnAssemblyAIFinalTranscriptReady(object? sender, TranscriptEventArgs args)
    {
        var finalText = args.Transcript.Length > 0 ? args.Transcript : _latestPartialTranscript;
        _finalTranscriptCompletionSource?.TrySetResult(finalText);
    }

    private void OnUpstreamSessionFaulted(object? sender, Exception exception)
    {
        SessionFaulted?.Invoke(this, exception);
        _finalTranscriptCompletionSource?.TrySetResult(_latestPartialTranscript);
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync(CancellationToken.None).ConfigureAwait(false);
        _microphoneCaptureService.Dispose();
        await _assemblyAIStreamingClient.DisposeAsync().ConfigureAwait(false);
    }
}
