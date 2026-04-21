namespace Clicky.Services;

/// <summary>
/// Cloudflare Worker proxy endpoints. Mirrors the single <c>workerBaseURL</c>
/// constant in the macOS <c>CompanionManager.swift</c>. All provider secrets
/// (Anthropic, Gemini, AssemblyAI, ElevenLabs) live on the Worker — the
/// desktop app ships with zero embedded keys and reaches the upstream APIs
/// only through these routes.
///
/// Swap <see cref="BaseUrl"/> for your own Worker deployment. Everything
/// else is derived from it.
/// </summary>
public static class WorkerConfig
{
    /// <summary>
    /// Base URL of the Cloudflare Worker deployment. Matches the placeholder
    /// used in the macOS source — replace with your own Worker subdomain
    /// before shipping.
    /// </summary>
    public const string BaseUrl = "https://your-worker-name.your-subdomain.workers.dev";

    public static string ChatClaudeUrl => $"{BaseUrl}/chat";
    public static string ChatGeminiUrl => $"{BaseUrl}/chat-gemini";
    public static string TranscribeTokenUrl => $"{BaseUrl}/transcribe-token";
    public static string TtsUrl => $"{BaseUrl}/tts";
}
