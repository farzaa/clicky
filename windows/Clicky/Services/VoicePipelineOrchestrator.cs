using System.Globalization;
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
    // Verbatim port of CompanionManager.companionVoiceResponseSystemPrompt.
    // Kept in sync with the macOS version so prompt-engineering tweaks there
    // translate directly. The trailing [POINT:...] tag is stripped before
    // TTS / display; the M4 overlay will start consuming it.
    private const string VoiceSystemPrompt =
        "you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.\n" +
        "\n" +
        "rules:\n" +
        "- default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.\n" +
        "- all lowercase, casual, warm. no emojis.\n" +
        "- write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.\n" +
        "- don't use abbreviations or symbols that sound weird read aloud. write \"for example\" not \"e.g.\", spell out small numbers.\n" +
        "- if the user's question relates to what's on their screen, reference specific things you see.\n" +
        "- if the screenshot doesn't seem relevant to their question, just answer the question directly.\n" +
        "- you can help with anything — coding, writing, general knowledge, brainstorming.\n" +
        "- never say \"simply\" or \"just\".\n" +
        "- don't read out code verbatim. describe what the code does or what needs to change conversationally.\n" +
        "- focus on giving a thorough, useful explanation. don't end with simple yes/no questions like \"want me to explain more?\" or \"should i show you?\" — those are dead ends that force the user to just say yes.\n" +
        "- instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.\n" +
        "- if you receive multiple screen images, the one labeled \"primary focus\" is where the cursor is — prioritize that one but reference others if relevant.\n" +
        "\n" +
        "element pointing:\n" +
        "you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.\n" +
        "\n" +
        "don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.\n" +
        "\n" +
        "when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.\n" +
        "\n" +
        "format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like \"search bar\" or \"save button\"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.\n" +
        "\n" +
        "if pointing wouldn't help, append [POINT:none].\n" +
        "\n" +
        "examples:\n" +
        "- user asks how to color grade in final cut: \"you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]\"\n" +
        "- user asks what html is: \"html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]\"\n" +
        "- user asks how to commit in xcode: \"see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]\"\n" +
        "- element is on screen 2 (not where cursor is): \"that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]\"";

    // Short "here!" phrases picked at random for the speech bubble the
    // triangle shows once it reaches the element. Mirrors the macOS list
    // in OverlayWindow.navigationBubblePhrases.
    private static readonly string[] PointerBubblePhrases =
    {
        "right here!",
        "this one!",
        "over here!",
        "click this!",
        "here it is!",
        "found it!",
    };

    private const int ConversationHistoryMaxTurns = 10;

    private readonly AppState _appState;
    private readonly Dispatcher _uiDispatcher;
    private readonly ClaudeClient _claudeClient;
    private readonly GeminiClient _geminiClient;
    private readonly ElevenLabsTtsClient _elevenLabsTtsClient;
    private readonly ScreenCaptureService _screenCaptureService;
    private readonly OverlayWindowManager? _overlayWindowManager;

    private DictationSession? _activeDictationSession;
    private readonly List<ConversationTurn> _conversationHistory = new();

    private CancellationTokenSource? _currentRequestCts;

    public VoicePipelineOrchestrator(
        AppState appState,
        Dispatcher uiDispatcher,
        OverlayWindowManager? overlayWindowManager = null)
    {
        _appState = appState;
        _uiDispatcher = uiDispatcher;
        _overlayWindowManager = overlayWindowManager;

        _claudeClient = new ClaudeClient(model: InferInitialClaudeModel(appState.SelectedModelId));
        _geminiClient = new GeminiClient(model: InferInitialGeminiModel(appState.SelectedModelId));
        _elevenLabsTtsClient = new ElevenLabsTtsClient();
        _elevenLabsTtsClient.PlaybackFinished += OnTtsPlaybackFinished;
        _screenCaptureService = new ScreenCaptureService();

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
            // Grab every monitor JPEG before contacting the model. BitBlt is
            // synchronous and runs on a thread pool thread so the UI doesn't
            // freeze while the capture happens. We also keep the raw capture
            // list so [POINT:…] coordinates can be mapped back to the matching
            // monitor's bounds once the reply is parsed.
            var capturedMonitors = await Task.Run(
                () => _screenCaptureService.CaptureAllMonitors(),
                cancellationToken).ConfigureAwait(false);
            var inlineImages = BuildInlineImagesFromCaptures(capturedMonitors);

            if (cancellationToken.IsCancellationRequested) return;

            var streamResult = await selectedClient.StreamChatAsync(
                systemPrompt: VoiceSystemPrompt,
                conversationHistory: _conversationHistory,
                userPrompt: userPrompt,
                images: inlineImages,
                onTextChunk: AppendToStreamedResponseOnUi,
                cancellationToken: cancellationToken).ConfigureAwait(false);

            if (cancellationToken.IsCancellationRequested) return;

            // Split the reply into spoken text + optional pointing target.
            // TTS speaks the spoken text; the flight fires before playback
            // starts so the triangle is already en route when the user
            // hears Clicky start talking.
            var pointingParseResult = PointingTagParser.Parse(streamResult.FullText);
            var spokenText = pointingParseResult.SpokenText;
            SetStreamedResponseOnUi(spokenText);

            AppendTurnToHistory(userPrompt, spokenText);

            TriggerPointingFlightIfRequested(pointingParseResult, capturedMonitors);

            if (spokenText.Length == 0)
            {
                SetVoiceStateOnUi(AppState.VoiceState.Idle);
                return;
            }

            SetVoiceStateOnUi(AppState.VoiceState.Responding);
            await _elevenLabsTtsClient.SpeakAsync(spokenText, cancellationToken).ConfigureAwait(false);
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

    /// <summary>
    /// Wraps each monitor capture into an <see cref="InlineImage"/> whose
    /// label matches the macOS format — "screen N of M — cursor is on this
    /// screen (primary focus) (image dimensions: WxH pixels)" — so the
    /// model's coordinate space maps to the pixels it actually sees.
    /// </summary>
    private static IReadOnlyList<InlineImage> BuildInlineImagesFromCaptures(IReadOnlyList<MonitorCapture> capturedMonitors)
    {
        if (capturedMonitors.Count == 0) return Array.Empty<InlineImage>();

        var inlineImages = new List<InlineImage>(capturedMonitors.Count);
        foreach (var monitorCapture in capturedMonitors)
        {
            var dimensionSuffix = string.Format(
                CultureInfo.InvariantCulture,
                " (image dimensions: {0}x{1} pixels)",
                monitorCapture.ScreenshotWidthPixels,
                monitorCapture.ScreenshotHeightPixels);

            inlineImages.Add(new InlineImage(
                Data: monitorCapture.JpegData,
                MimeType: monitorCapture.MimeType,
                Label: monitorCapture.Label + dimensionSuffix));
        }
        return inlineImages;
    }

    /// <summary>
    /// Maps a parsed <c>[POINT:x,y:label:screenN]</c> tag back to a concrete
    /// overlay flight: picks the target monitor (by screen index, defaulting
    /// to the cursor's monitor i.e. index 0), rescales screenshot pixels to
    /// the monitor's native device pixels, clamps into bounds, and tells the
    /// <see cref="OverlayWindowManager"/> to fly the triangle there.
    /// </summary>
    private void TriggerPointingFlightIfRequested(
        PointingParseResult parseResult,
        IReadOnlyList<MonitorCapture> capturedMonitors)
    {
        if (_overlayWindowManager is null) return;
        if (parseResult.Coordinate is not (int pointX, int pointY)) return;
        if (capturedMonitors.Count == 0) return;

        // screenNumber is 1-based and indexes into the cursor-first capture
        // list. Out-of-range values fall back to the cursor's screen so a
        // sloppy AI reply still lands somewhere sensible.
        var targetCaptureIndex = 0;
        if (parseResult.ScreenNumber is int screenNumber)
        {
            var candidateIndex = screenNumber - 1;
            if (candidateIndex >= 0 && candidateIndex < capturedMonitors.Count)
            {
                targetCaptureIndex = candidateIndex;
            }
        }

        var targetCapture = capturedMonitors[targetCaptureIndex];
        if (targetCapture.ScreenshotWidthPixels <= 0 || targetCapture.ScreenshotHeightPixels <= 0) return;

        // Screenshot coords → display-local device pixels. The JPEG may be
        // downscaled (MaxLongestSidePixels in ScreenCaptureService), so we
        // rescale to the monitor's native resolution before handing off.
        var screenshotScaleX = (double)targetCapture.DisplayWidthPixels / targetCapture.ScreenshotWidthPixels;
        var screenshotScaleY = (double)targetCapture.DisplayHeightPixels / targetCapture.ScreenshotHeightPixels;
        var displayLocalDeviceX = Math.Clamp(pointX * screenshotScaleX, 0, targetCapture.DisplayWidthPixels - 1);
        var displayLocalDeviceY = Math.Clamp(pointY * screenshotScaleY, 0, targetCapture.DisplayHeightPixels - 1);

        var bubblePhrase = PointerBubblePhrases[Random.Shared.Next(PointerBubblePhrases.Length)];

        _overlayWindowManager.FlyToElement(
            targetMonitorBoundsLeftDevicePixels: targetCapture.DisplayBoundsDevicePixels.X,
            targetMonitorBoundsTopDevicePixels: targetCapture.DisplayBoundsDevicePixels.Y,
            targetDisplayLocalDeviceX: displayLocalDeviceX,
            targetDisplayLocalDeviceY: displayLocalDeviceY,
            bubblePhrase: bubblePhrase);
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
