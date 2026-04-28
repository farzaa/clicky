namespace Clicky.Services;

/// <summary>
/// Provider-agnostic streaming chat interface. Both <see cref="ClaudeClient"/>
/// and <see cref="GeminiClient"/> implement it so the orchestrator can swap
/// providers based on the user's model selection without caring which is
/// running. Mirrors the shared shape that <c>ClaudeAPI.swift</c> and
/// <c>GeminiAPI.swift</c> expose on macOS.
/// </summary>
public interface IChatClient
{
    /// <summary>
    /// Model identifier sent to the provider. Setter is used when the user
    /// changes the selection in the tray panel mid-session.
    /// </summary>
    string Model { get; set; }

    /// <summary>
    /// Streams a response for <paramref name="userPrompt"/> given the
    /// accumulated <paramref name="conversationHistory"/> and the optional
    /// <paramref name="images"/> (inline base64 parts on the wire).
    /// <paramref name="onTextChunk"/> fires on the calling thread for every
    /// incremental text delta; the returned task resolves with the full
    /// accumulated text once the stream closes.
    /// </summary>
    Task<ChatStreamResult> StreamChatAsync(
        string systemPrompt,
        IReadOnlyList<ConversationTurn> conversationHistory,
        string userPrompt,
        IReadOnlyList<InlineImage> images,
        Action<string> onTextChunk,
        CancellationToken cancellationToken);
}

/// <summary>A completed (user, assistant) pair in the rolling history.</summary>
public sealed record ConversationTurn(string UserMessage, string AssistantMessage);

/// <summary>
/// Inline image for vision calls — raw bytes plus IANA media type, and an
/// optional <paramref name="Label"/>. When <c>Label</c> is non-null the chat
/// clients emit it as a text part immediately before the image so the model
/// knows which screen it's looking at (e.g. "screen 1 of 2 — cursor is on
/// this screen (primary focus) (image dimensions: 1280x800 pixels)"). This
/// matches the macOS <c>analyzeImageStreaming</c> contract.
/// </summary>
public sealed record InlineImage(byte[] Data, string MimeType, string? Label = null);

/// <summary>Result of a streaming chat call — full accumulated text + wall time.</summary>
public sealed record ChatStreamResult(string FullText, TimeSpan Duration);
