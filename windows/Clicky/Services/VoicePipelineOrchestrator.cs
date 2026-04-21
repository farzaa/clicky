using System.Windows.Threading;

namespace Clicky.Services;

/// <summary>
/// End-to-end voice pipeline. Drives the push-to-talk flow:
///   press   → mic + AssemblyAI start, <c>AppState.VoiceState.Listening</c>
///   release → finalize transcript, dispatch to Claude/Gemini streaming
///             (<c>VoiceState.Processing</c>), stream response to the
///             panel, hand the final caption to ElevenLabs for playback
///             (<c>VoiceState.Responding</c>), return to
///             <c>VoiceState.Idle</c> when audio stops.
///
/// The macOS equivalent is the transcript→AI→TTS pipeline embedded in
/// <c>CompanionManager.swift</c>. We pulled it into its own class on
/// Windows so <c>App.xaml.cs</c> and <c>AppState</c> stay small.
/// </summary>
public sealed class VoicePipelineOrchestrator : IAsyncDisposable
{
    // Kept short because TTS reads the reply out loud — a long monologue
    // makes the app feel sluggish. Mirrors the macOS Buddy personality.
    private const string VoiceSystemPrompt =
        "You are Clicky, a concise and friendly voice assistant. Reply in one or two short sentences " +
        "suitable for being read aloud. Avoid lists and markdown. If the user asks you to point at " +
        "something, say what you would point at in plain words — the visual pointing feature is not " +
        "available in this milestone.";

    private const int ConversationHistoryMaxTurns = 10;

    private readonly AppState _appState;
    private readonly Dispatcher _uiDispatcher;
    private readonly ClaudeClient _claudeClient;
    private readonly GeminiClient _geminiClient;
    private readonly ElevenLabsTtsClient _elevenLabsTtsClient;

    private DictationSession? _activeDictationSession;
    private readonly List<ConversationTurn> _conversationHistory = new();

    private CancellationTokenSource? _currentRequestCts;

    public VoicePipelineOrchestrator(AppState appState, Dispatcher uiDispatcher)
    {
        _appState = appState;
        _uiDispatcher = uiDispatcher;

        _claudeClient = new ClaudeClient(model: InferInitialClaudeModel(appState.SelectedModelId));
        _geminiClient = new GeminiClient(model: InferInitialGeminiModel(appState.SelectedModelId));
        _elevenLabsTtsClient = new ElevenLabsTtsClient();
        _elevenLabsTtsClient.PlaybackFinished += OnTtsPlaybackFinished;

        _appState.PropertyChanged += OnAppStatePropertyChanged;
    }

    public async Task HandlePushToTalkPressedAsync()
    {
        // Talking over the previous reply → cancel in-flight AI request and
        // stop TTS so the user isn't competing with the assistant's voice.
        _currentRequestCts?.Cancel();
        _elevenLabsTtsClient.StopPlayback();

        SetVoiceStateOnUi(AppState.VoiceState.Listening);
        SetLiveTranscriptOnUi(string.Empty);
        SetStreamedResponseOnUi(string.Empty);

        try
        {
            var newSession = new DictationSession();
            newSession.PartialTranscriptUpdated += OnPartialTranscriptUpdated;
            newSession.SessionFaulted += OnDictationFaulted;
            await newSession.StartAsync(CancellationToken.None).ConfigureAwait(false);
            _activeDictationSession = newSession;
        }
        catch (Exception startException)
        {
            SetVoiceStateOnUi(AppState.VoiceState.Idle);
            ReportFailureOnUi($"Couldn't start dictation: {startException.Message}");
        }
    }

    public async Task HandlePushToTalkReleasedAsync()
    {
        var releasedSession = _activeDictationSession;
        if (releasedSession is null)
        {
            SetVoiceStateOnUi(AppState.VoiceState.Idle);
            return;
        }

        SetVoiceStateOnUi(AppState.VoiceState.Processing);

        string finalTranscript;
        try
        {
            finalTranscript = await releasedSession.RequestFinalTranscriptAsync(CancellationToken.None)
                .ConfigureAwait(false);
        }
        catch (Exception finalizeException)
        {
            SetVoiceStateOnUi(AppState.VoiceState.Idle);
            ReportFailureOnUi($"Transcription ended unexpectedly: {finalizeException.Message}");
            await TeardownDictationSessionAsync(releasedSession).ConfigureAwait(false);
            return;
        }

        await TeardownDictationSessionAsync(releasedSession).ConfigureAwait(false);

        if (string.IsNullOrWhiteSpace(finalTranscript))
        {
            SetVoiceStateOnUi(AppState.VoiceState.Idle);
            return;
        }

        SetLiveTranscriptOnUi(finalTranscript);
        await DispatchToAiAndSpeakAsync(finalTranscript).ConfigureAwait(false);
    }

    private async Task DispatchToAiAndSpeakAsync(string userPrompt)
    {
        _currentRequestCts?.Dispose();
        _currentRequestCts = new CancellationTokenSource();
        var cancellationToken = _currentRequestCts.Token;

        var selectedClient = ResolveClientForCurrentModel();

        try
        {
            var streamResult = await selectedClient.StreamChatAsync(
                systemPrompt: VoiceSystemPrompt,
                conversationHistory: _conversationHistory,
                userPrompt: userPrompt,
                images: Array.Empty<InlineImage>(),
                onTextChunk: AppendToStreamedResponseOnUi,
                cancellationToken: cancellationToken).ConfigureAwait(false);

            if (cancellationToken.IsCancellationRequested) return;

            AppendTurnToHistory(userPrompt, streamResult.FullText);

            if (streamResult.FullText.Length == 0)
            {
                SetVoiceStateOnUi(AppState.VoiceState.Idle);
                return;
            }

            SetVoiceStateOnUi(AppState.VoiceState.Responding);
            await _elevenLabsTtsClient.SpeakAsync(streamResult.FullText, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            // User cut us off — leave the state reset to the next handler.
        }
        catch (Exception aiException)
        {
            SetVoiceStateOnUi(AppState.VoiceState.Idle);
            ReportFailureOnUi($"AI request failed: {aiException.Message}");
        }
    }

    private IChatClient ResolveClientForCurrentModel()
    {
        var currentModelId = _appState.SelectedModelId;
        if (AppState.IsGeminiModelId(currentModelId))
        {
            _geminiClient.Model = currentModelId;
            return _geminiClient;
        }
        _claudeClient.Model = currentModelId;
        return _claudeClient;
    }

    private void AppendTurnToHistory(string userPrompt, string assistantReply)
    {
        _conversationHistory.Add(new ConversationTurn(userPrompt, assistantReply));
        while (_conversationHistory.Count > ConversationHistoryMaxTurns)
        {
            _conversationHistory.RemoveAt(0);
        }
    }

    private async Task TeardownDictationSessionAsync(DictationSession session)
    {
        session.PartialTranscriptUpdated -= OnPartialTranscriptUpdated;
        session.SessionFaulted -= OnDictationFaulted;
        try
        {
            await session.StopAsync(CancellationToken.None).ConfigureAwait(false);
        }
        catch { /* tearing down — best effort */ }
        await session.DisposeAsync().ConfigureAwait(false);
        if (ReferenceEquals(_activeDictationSession, session))
        {
            _activeDictationSession = null;
        }
    }

    private void OnPartialTranscriptUpdated(object? sender, string partialTranscript)
    {
        SetLiveTranscriptOnUi(partialTranscript);
    }

    private void OnDictationFaulted(object? sender, Exception exception)
    {
        ReportFailureOnUi($"Dictation error: {exception.Message}");
        SetVoiceStateOnUi(AppState.VoiceState.Idle);
    }

    private void OnTtsPlaybackFinished(object? sender, EventArgs eventArgs)
    {
        SetVoiceStateOnUi(AppState.VoiceState.Idle);
    }

    private void OnAppStatePropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs args)
    {
        // Keep the chat clients' models in sync with the user's selection
        // so a mid-conversation switch takes effect on the next turn.
        if (args.PropertyName == nameof(AppState.SelectedModelId))
        {
            ResolveClientForCurrentModel();
        }
    }

    // ---- UI marshaling helpers ----

    private void SetVoiceStateOnUi(AppState.VoiceState newState)
    {
        _uiDispatcher.BeginInvoke(() => _appState.CurrentVoiceState = newState);
    }

    private void SetLiveTranscriptOnUi(string transcript)
    {
        _uiDispatcher.BeginInvoke(() => _appState.LiveTranscript = transcript);
    }

    private void SetStreamedResponseOnUi(string newText)
    {
        _uiDispatcher.BeginInvoke(() => _appState.StreamedResponseText = newText);
    }

    private void AppendToStreamedResponseOnUi(string textChunk)
    {
        _uiDispatcher.BeginInvoke(() => _appState.StreamedResponseText += textChunk);
    }

    private void ReportFailureOnUi(string failureMessage)
    {
        _uiDispatcher.BeginInvoke(() => _appState.LastStatusMessage = failureMessage);
    }

    // ---- Model defaults ----

    private static string InferInitialClaudeModel(string selectedModelId)
    {
        return AppState.IsGeminiModelId(selectedModelId) ? ClaudeClient.DefaultModel : selectedModelId;
    }

    private static string InferInitialGeminiModel(string selectedModelId)
    {
        return AppState.IsGeminiModelId(selectedModelId) ? selectedModelId : GeminiClient.DefaultModel;
    }

    public async ValueTask DisposeAsync()
    {
        _appState.PropertyChanged -= OnAppStatePropertyChanged;
        _currentRequestCts?.Cancel();
        _currentRequestCts?.Dispose();

        if (_activeDictationSession is not null)
        {
            await TeardownDictationSessionAsync(_activeDictationSession).ConfigureAwait(false);
        }

        _elevenLabsTtsClient.PlaybackFinished -= OnTtsPlaybackFinished;
        _elevenLabsTtsClient.Dispose();
        _claudeClient.Dispose();
        _geminiClient.Dispose();
    }
}
