using System.IO;
using System.Net.Http;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;

namespace Clicky.Services;

/// <summary>
/// Streaming AssemblyAI realtime transcription over WebSocket (v3).
/// Port of <c>AssemblyAIStreamingTranscriptionProvider.swift</c>.
///
/// Lifecycle:
///   1. <see cref="StartAsync"/>  — fetches a temporary token from the
///      Worker, opens the websocket with the required query params, and
///      spawns a background receive loop.
///   2. <see cref="AppendAudio"/> — caller pushes raw PCM16 little-endian
///      16-kHz mono frames; they're forwarded as binary websocket messages.
///   3. <see cref="RequestFinalTranscriptAsync"/> — sends <c>ForceEndpoint</c>
///      to flush the partial into a final turn.
///   4. <see cref="StopAsync"/>  — sends <c>Terminate</c>, closes the socket.
///
/// The class raises two events on a worker thread. Marshal to the UI thread
/// at the call site if needed.
/// </summary>
public sealed class AssemblyAIStreamingClient : IAsyncDisposable
{
    private const int SampleRateHz = 16_000;
    private const string SpeechModel = "u3-rt-pro";

    private readonly HttpClient _tokenHttpClient = new() { Timeout = TimeSpan.FromSeconds(20) };
    private ClientWebSocket? _webSocket;
    private Task? _receiveLoopTask;
    private Task? _sendLoopTask;
    private CancellationTokenSource? _lifetimeCts;
    private Channel<ReadOnlyMemory<byte>>? _audioChannel;

    /// <summary>Partial or final transcript text — fires on every Turn message.</summary>
    public event EventHandler<TranscriptEventArgs>? TranscriptUpdated;

    /// <summary>Fires once when AssemblyAI signals end-of-turn (final transcript).</summary>
    public event EventHandler<TranscriptEventArgs>? FinalTranscriptReady;

    /// <summary>Fires if the session errors out (network, upstream rejection).</summary>
    public event EventHandler<Exception>? SessionFaulted;

    public bool IsRunning => _webSocket?.State == WebSocketState.Open;

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        var temporaryToken = await FetchTemporaryTokenAsync(cancellationToken).ConfigureAwait(false);
        var websocketUri = BuildWebsocketUri(temporaryToken);

        _lifetimeCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        _webSocket = new ClientWebSocket();
        await _webSocket.ConnectAsync(websocketUri, _lifetimeCts.Token).ConfigureAwait(false);

        _audioChannel = Channel.CreateUnbounded<ReadOnlyMemory<byte>>(new UnboundedChannelOptions
        {
            SingleReader = true,
            SingleWriter = false,
            AllowSynchronousContinuations = false,
        });

        _receiveLoopTask = Task.Run(() => RunReceiveLoopAsync(_lifetimeCts.Token));
        _sendLoopTask = Task.Run(() => RunSendLoopAsync(_lifetimeCts.Token));
    }

    /// <summary>
    /// Enqueue a PCM16 frame for transmission. Non-blocking — frames are
    /// buffered in an unbounded channel and flushed by the background sender.
    /// </summary>
    public void AppendAudio(ReadOnlyMemory<byte> pcm16LittleEndianBytes)
    {
        _audioChannel?.Writer.TryWrite(pcm16LittleEndianBytes);
    }

    /// <summary>
    /// Tells AssemblyAI to cut the current partial into a final turn without
    /// waiting for natural silence. Used when the user releases push-to-talk.
    /// </summary>
    public async Task RequestFinalTranscriptAsync(CancellationToken cancellationToken)
    {
        if (_webSocket?.State != WebSocketState.Open) return;
        var forceEndpointJson = Encoding.UTF8.GetBytes("{\"type\":\"ForceEndpoint\"}");
        await _webSocket.SendAsync(forceEndpointJson, WebSocketMessageType.Text, endOfMessage: true, cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task StopAsync(CancellationToken cancellationToken)
    {
        if (_webSocket is null) return;

        try
        {
            if (_webSocket.State == WebSocketState.Open)
            {
                var terminateJson = Encoding.UTF8.GetBytes("{\"type\":\"Terminate\"}");
                await _webSocket.SendAsync(terminateJson, WebSocketMessageType.Text, endOfMessage: true, cancellationToken)
                    .ConfigureAwait(false);
                await _webSocket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "client-terminate", cancellationToken)
                    .ConfigureAwait(false);
            }
        }
        catch (WebSocketException) { /* socket already closed — ignore */ }
        catch (OperationCanceledException) { /* shutdown during cancel — ignore */ }

        _lifetimeCts?.Cancel();
        _audioChannel?.Writer.TryComplete();

        try { if (_sendLoopTask is not null) await _sendLoopTask.ConfigureAwait(false); }
        catch (OperationCanceledException) { /* expected */ }

        try { if (_receiveLoopTask is not null) await _receiveLoopTask.ConfigureAwait(false); }
        catch (OperationCanceledException) { /* expected */ }

        _webSocket.Dispose();
        _webSocket = null;
    }

    private async Task<string> FetchTemporaryTokenAsync(CancellationToken cancellationToken)
    {
        using var tokenRequest = new HttpRequestMessage(HttpMethod.Post, WorkerConfig.TranscribeTokenUrl);
        using var tokenResponse = await _tokenHttpClient.SendAsync(tokenRequest, cancellationToken).ConfigureAwait(false);
        tokenResponse.EnsureSuccessStatusCode();

        var responseBody = await tokenResponse.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        using var parsedDocument = JsonDocument.Parse(responseBody);
        if (!parsedDocument.RootElement.TryGetProperty("token", out var tokenProperty))
        {
            throw new InvalidOperationException($"Token proxy response missing 'token' field: {responseBody}");
        }

        var tokenValue = tokenProperty.GetString();
        if (string.IsNullOrWhiteSpace(tokenValue))
        {
            throw new InvalidOperationException("Token proxy returned an empty token.");
        }
        return tokenValue;
    }

    private static Uri BuildWebsocketUri(string temporaryToken)
    {
        var encodedToken = Uri.EscapeDataString(temporaryToken);
        var queryString =
            $"sample_rate={SampleRateHz}" +
            $"&encoding=pcm_s16le" +
            $"&format_turns=true" +
            $"&speech_model={SpeechModel}" +
            $"&token={encodedToken}";
        return new Uri($"wss://streaming.assemblyai.com/v3/ws?{queryString}");
    }

    private async Task RunSendLoopAsync(CancellationToken cancellationToken)
    {
        if (_audioChannel is null || _webSocket is null) return;
        var channelReader = _audioChannel.Reader;

        try
        {
            while (await channelReader.WaitToReadAsync(cancellationToken).ConfigureAwait(false))
            {
                while (channelReader.TryRead(out var pcmFrame))
                {
                    if (_webSocket.State != WebSocketState.Open) return;
                    await _webSocket.SendAsync(pcmFrame, WebSocketMessageType.Binary, endOfMessage: true, cancellationToken)
                        .ConfigureAwait(false);
                }
            }
        }
        catch (OperationCanceledException) { /* shutdown — ignore */ }
        catch (WebSocketException webSocketException)
        {
            SessionFaulted?.Invoke(this, webSocketException);
        }
    }

    private async Task RunReceiveLoopAsync(CancellationToken cancellationToken)
    {
        if (_webSocket is null) return;
        var receiveBuffer = new byte[16 * 1024];
        var messageBuffer = new MemoryStream();

        try
        {
            while (_webSocket.State == WebSocketState.Open && !cancellationToken.IsCancellationRequested)
            {
                messageBuffer.SetLength(0);
                WebSocketReceiveResult receiveResult;
                do
                {
                    receiveResult = await _webSocket
                        .ReceiveAsync(new ArraySegment<byte>(receiveBuffer), cancellationToken)
                        .ConfigureAwait(false);

                    if (receiveResult.MessageType == WebSocketMessageType.Close)
                    {
                        return;
                    }

                    messageBuffer.Write(receiveBuffer, 0, receiveResult.Count);
                } while (!receiveResult.EndOfMessage);

                if (receiveResult.MessageType != WebSocketMessageType.Text) continue;

                var messageText = Encoding.UTF8.GetString(messageBuffer.GetBuffer(), 0, (int)messageBuffer.Length);
                HandleIncomingMessage(messageText);
            }
        }
        catch (OperationCanceledException) { /* shutdown — ignore */ }
        catch (WebSocketException webSocketException)
        {
            SessionFaulted?.Invoke(this, webSocketException);
        }
    }

    /// <summary>
    /// Parses an AssemblyAI v3 realtime message. We only act on
    /// <c>Turn</c> messages; session lifecycle (<c>Begin</c>,
    /// <c>Termination</c>) doesn't need caller notification here.
    /// </summary>
    private void HandleIncomingMessage(string messageText)
    {
        try
        {
            using var parsedDocument = JsonDocument.Parse(messageText);
            var rootObject = parsedDocument.RootElement;
            if (!rootObject.TryGetProperty("type", out var typeProperty)) return;

            var messageType = typeProperty.GetString();
            if (messageType != "Turn") return;

            var transcriptText = rootObject.TryGetProperty("transcript", out var transcriptProperty)
                ? transcriptProperty.GetString() ?? string.Empty
                : string.Empty;

            var isEndOfTurn = rootObject.TryGetProperty("end_of_turn", out var endOfTurnProperty)
                && endOfTurnProperty.ValueKind == JsonValueKind.True;
            var isFormatted = rootObject.TryGetProperty("turn_is_formatted", out var formattedProperty)
                && formattedProperty.ValueKind == JsonValueKind.True;
            var isFinal = isEndOfTurn || isFormatted;

            var eventArgs = new TranscriptEventArgs(transcriptText, isFinal);
            TranscriptUpdated?.Invoke(this, eventArgs);
            if (isFinal)
            {
                FinalTranscriptReady?.Invoke(this, eventArgs);
            }
        }
        catch (JsonException)
        {
            // Malformed message — ignore rather than fault the session;
            // AssemblyAI occasionally emits empty keepalive frames.
        }
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync(CancellationToken.None).ConfigureAwait(false);
        _lifetimeCts?.Dispose();
        _tokenHttpClient.Dispose();
    }
}

public sealed class TranscriptEventArgs : EventArgs
{
    public TranscriptEventArgs(string transcript, bool isFinal)
    {
        Transcript = transcript;
        IsFinal = isFinal;
    }

    public string Transcript { get; }
    public bool IsFinal { get; }
}
