using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace Clicky.Services;

/// <summary>
/// Streaming Anthropic Messages client. Talks to the Cloudflare Worker's
/// <c>/chat</c> route — the Worker injects the API key and forwards the
/// SSE stream unchanged. Port of <c>ClaudeAPI.swift</c>.
/// </summary>
public sealed class ClaudeClient : IChatClient, IDisposable
{
    public const string DefaultModel = "claude-sonnet-4-6";
    private const int MaxOutputTokens = 1024;

    private readonly HttpClient _httpClient;
    private readonly bool _ownsHttpClient;

    public string Model { get; set; }

    public ClaudeClient(string model = DefaultModel, HttpClient? httpClient = null)
    {
        Model = model;
        if (httpClient is null)
        {
            _httpClient = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
            _ownsHttpClient = true;
        }
        else
        {
            _httpClient = httpClient;
            _ownsHttpClient = false;
        }
    }

    public async Task<ChatStreamResult> StreamChatAsync(
        string systemPrompt,
        IReadOnlyList<ConversationTurn> conversationHistory,
        string userPrompt,
        IReadOnlyList<InlineImage> images,
        Action<string> onTextChunk,
        CancellationToken cancellationToken)
    {
        var stopwatch = Stopwatch.StartNew();

        var requestPayload = BuildRequestPayload(systemPrompt, conversationHistory, userPrompt, images);
        using var requestMessage = new HttpRequestMessage(HttpMethod.Post, WorkerConfig.ChatClaudeUrl)
        {
            Content = new StringContent(requestPayload, Encoding.UTF8, "application/json"),
        };
        requestMessage.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("text/event-stream"));

        using var responseMessage = await _httpClient
            .SendAsync(requestMessage, HttpCompletionOption.ResponseHeadersRead, cancellationToken)
            .ConfigureAwait(false);

        if (!responseMessage.IsSuccessStatusCode)
        {
            var errorBody = await responseMessage.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            throw new HttpRequestException(
                $"Claude proxy returned {(int)responseMessage.StatusCode}: {errorBody}");
        }

        await using var responseStream = await responseMessage.Content
            .ReadAsStreamAsync(cancellationToken)
            .ConfigureAwait(false);
        using var streamReader = new StreamReader(responseStream, Encoding.UTF8);

        var accumulatedText = new StringBuilder();

        // SSE frames are separated by blank lines. Within a frame we care
        // about the `data:` lines; Anthropic also emits `event:` lines but
        // the JSON payload carries its own `type` so we don't need them.
        string? currentLine;
        while ((currentLine = await streamReader.ReadLineAsync(cancellationToken).ConfigureAwait(false)) is not null)
        {
            if (currentLine.Length == 0) continue;
            if (!currentLine.StartsWith("data:", StringComparison.Ordinal)) continue;

            var jsonPayload = currentLine.AsSpan(5).TrimStart().ToString();
            if (jsonPayload == "[DONE]") break;
            if (jsonPayload.Length == 0) continue;

            var chunk = ParseTextDelta(jsonPayload);
            if (chunk.Length > 0)
            {
                accumulatedText.Append(chunk);
                onTextChunk(chunk);
            }
        }

        stopwatch.Stop();
        return new ChatStreamResult(accumulatedText.ToString(), stopwatch.Elapsed);
    }

    /// <summary>
    /// Extracts the <c>delta.text</c> string from an Anthropic streaming
    /// payload, or returns empty if this event type doesn't carry text.
    /// Anthropic emits many event types (<c>message_start</c>,
    /// <c>content_block_start</c>, <c>ping</c>, <c>message_delta</c>, etc.)
    /// — we only act on <c>content_block_delta</c> with a
    /// <c>text_delta</c> payload, which mirrors the macOS client.
    /// </summary>
    private static string ParseTextDelta(string jsonPayload)
    {
        try
        {
            using var parsedDocument = JsonDocument.Parse(jsonPayload);
            var rootObject = parsedDocument.RootElement;
            if (!rootObject.TryGetProperty("type", out var typeProperty)) return string.Empty;
            if (typeProperty.GetString() != "content_block_delta") return string.Empty;
            if (!rootObject.TryGetProperty("delta", out var deltaProperty)) return string.Empty;
            if (!deltaProperty.TryGetProperty("type", out var deltaTypeProperty)) return string.Empty;
            if (deltaTypeProperty.GetString() != "text_delta") return string.Empty;
            if (!deltaProperty.TryGetProperty("text", out var textProperty)) return string.Empty;
            return textProperty.GetString() ?? string.Empty;
        }
        catch (JsonException)
        {
            return string.Empty;
        }
    }

    private string BuildRequestPayload(
        string systemPrompt,
        IReadOnlyList<ConversationTurn> conversationHistory,
        string userPrompt,
        IReadOnlyList<InlineImage> images)
    {
        // Anthropic accepts either a plain string or an array of content
        // parts. We use the array form for the latest user turn so we can
        // include images; historical turns have no images and can stay
        // as plain strings to keep the payload compact.
        var messageArray = new List<object>(conversationHistory.Count * 2 + 1);
        foreach (var historicalTurn in conversationHistory)
        {
            messageArray.Add(new { role = "user", content = historicalTurn.UserMessage });
            messageArray.Add(new { role = "assistant", content = historicalTurn.AssistantMessage });
        }

        // Each image is followed by a text part carrying its label so the
        // model can distinguish multiple screens (e.g. "screen 1 of 2 — …").
        // Mirrors the macOS ClaudeAPI.analyzeImageStreaming payload shape.
        var latestUserContentParts = new List<object>(images.Count * 2 + 1);
        foreach (var image in images)
        {
            latestUserContentParts.Add(new
            {
                type = "image",
                source = new
                {
                    type = "base64",
                    media_type = image.MimeType,
                    data = Convert.ToBase64String(image.Data),
                },
            });
            if (!string.IsNullOrEmpty(image.Label))
            {
                latestUserContentParts.Add(new { type = "text", text = image.Label });
            }
        }
        latestUserContentParts.Add(new { type = "text", text = userPrompt });
        messageArray.Add(new { role = "user", content = latestUserContentParts });

        var requestObject = new
        {
            model = Model,
            max_tokens = MaxOutputTokens,
            stream = true,
            system = systemPrompt,
            messages = messageArray,
        };

        return JsonSerializer.Serialize(requestObject);
    }

    public void Dispose()
    {
        if (_ownsHttpClient) _httpClient.Dispose();
    }
}
