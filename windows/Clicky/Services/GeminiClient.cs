using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace Clicky.Services;

/// <summary>
/// Streaming Google Gemini client. Talks to the Cloudflare Worker's
/// <c>/chat-gemini</c> route. The Worker extracts the <c>model</c> field
/// from the body (Gemini requires it in the URL path) and forwards the
/// rest. Port of <c>GeminiAPI.swift</c>.
/// </summary>
public sealed class GeminiClient : IChatClient, IDisposable
{
    public const string DefaultModel = "gemini-2.5-flash";
    private const int MaxOutputTokens = 1024;

    private readonly HttpClient _httpClient;
    private readonly bool _ownsHttpClient;

    public string Model { get; set; }

    public GeminiClient(string model = DefaultModel, HttpClient? httpClient = null)
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
        using var requestMessage = new HttpRequestMessage(HttpMethod.Post, WorkerConfig.ChatGeminiUrl)
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
                $"Gemini proxy returned {(int)responseMessage.StatusCode}: {errorBody}");
        }

        await using var responseStream = await responseMessage.Content
            .ReadAsStreamAsync(cancellationToken)
            .ConfigureAwait(false);
        using var streamReader = new StreamReader(responseStream, Encoding.UTF8);

        var accumulatedText = new StringBuilder();

        string? currentLine;
        while ((currentLine = await streamReader.ReadLineAsync(cancellationToken).ConfigureAwait(false)) is not null)
        {
            if (currentLine.Length == 0) continue;
            if (!currentLine.StartsWith("data:", StringComparison.Ordinal)) continue;

            var jsonPayload = currentLine.AsSpan(5).TrimStart().ToString();
            if (jsonPayload.Length == 0) continue;

            var chunk = ExtractTextFromGeminiChunk(jsonPayload);
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
    /// Reads <c>candidates[0].content.parts[*].text</c> from a Gemini SSE
    /// chunk and concatenates all text parts. Gemini may split a single
    /// emission across multiple parts.
    /// </summary>
    private static string ExtractTextFromGeminiChunk(string jsonPayload)
    {
        try
        {
            using var parsedDocument = JsonDocument.Parse(jsonPayload);
            var rootObject = parsedDocument.RootElement;
            if (!rootObject.TryGetProperty("candidates", out var candidatesProperty)) return string.Empty;
            if (candidatesProperty.ValueKind != JsonValueKind.Array || candidatesProperty.GetArrayLength() == 0) return string.Empty;
            var firstCandidate = candidatesProperty[0];
            if (!firstCandidate.TryGetProperty("content", out var contentProperty)) return string.Empty;
            if (!contentProperty.TryGetProperty("parts", out var partsProperty)) return string.Empty;
            if (partsProperty.ValueKind != JsonValueKind.Array) return string.Empty;

            var combinedTextBuilder = new StringBuilder();
            foreach (var singlePart in partsProperty.EnumerateArray())
            {
                if (singlePart.TryGetProperty("text", out var textProperty) && textProperty.ValueKind == JsonValueKind.String)
                {
                    combinedTextBuilder.Append(textProperty.GetString());
                }
            }
            return combinedTextBuilder.ToString();
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
        // Gemini's roles are "user" and "model" (not "assistant"). System
        // instructions ride in a separate top-level field. Inline images
        // use `inline_data` with snake_case field names.
        var contentsArray = new List<object>(conversationHistory.Count * 2 + 1);
        foreach (var historicalTurn in conversationHistory)
        {
            contentsArray.Add(new
            {
                role = "user",
                parts = new object[] { new { text = historicalTurn.UserMessage } },
            });
            contentsArray.Add(new
            {
                role = "model",
                parts = new object[] { new { text = historicalTurn.AssistantMessage } },
            });
        }

        var latestUserParts = new List<object>(images.Count + 1);
        foreach (var image in images)
        {
            latestUserParts.Add(new
            {
                inline_data = new
                {
                    mime_type = image.MimeType,
                    data = Convert.ToBase64String(image.Data),
                },
            });
        }
        latestUserParts.Add(new { text = userPrompt });
        contentsArray.Add(new { role = "user", parts = latestUserParts });

        var requestObject = new
        {
            model = Model,
            systemInstruction = new
            {
                parts = new object[] { new { text = systemPrompt } },
            },
            contents = contentsArray,
            generationConfig = new
            {
                maxOutputTokens = MaxOutputTokens,
            },
        };

        return JsonSerializer.Serialize(requestObject);
    }

    public void Dispose()
    {
        if (_ownsHttpClient) _httpClient.Dispose();
    }
}
