using System.Diagnostics;
using System.Net.Http;
using System.Reflection;
using System.Text;
using System.Text.Json;

namespace Clicky.Services;

/// <summary>
/// Fire-and-forget PostHog client. Mirrors the event surface of the macOS
/// <c>ClickyAnalytics.swift</c> so the two clients show up side-by-side in
/// the same PostHog project.
///
/// Calls POST directly to <c>/capture/</c> — one small HTTP request per
/// event, no batching — which is plenty for the event volume a single
/// desktop app produces. The whole class is a no-op unless
/// <see cref="Configure"/> has been called with a real write key; swap the
/// placeholder in <see cref="WorkerConfig.PostHogWriteKey"/> to turn on.
///
/// Thread-safety: every method is safe to call from any thread. Failures
/// never propagate — analytics must never break the app.
/// </summary>
public static class ClickyAnalytics
{
    private const string PlaceholderWriteKey = "phc_YOUR_POSTHOG_WRITE_KEY_HERE";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    private static HttpClient? _httpClient;
    private static string? _distinctId;
    private static string? _appVersion;
    private static bool _isEnabled;

    /// <summary>
    /// Wires the PostHog client with the persisted distinct-id. Idempotent —
    /// safe to call more than once. Fires <c>app_opened</c> as soon as the
    /// first call succeeds.
    /// </summary>
    public static void Configure(string distinctId)
    {
        if (_httpClient is not null) return;

        if (string.IsNullOrWhiteSpace(WorkerConfig.PostHogWriteKey)
            || string.Equals(WorkerConfig.PostHogWriteKey, PlaceholderWriteKey, StringComparison.Ordinal))
        {
            _isEnabled = false;
            return;
        }

        _httpClient = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(10),
        };
        _distinctId = distinctId;
        _appVersion = Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "unknown";
        _isEnabled = true;

        TrackAppOpened();
    }

    // ---- Event helpers (one per macOS ClickyAnalytics case) ----

    public static void TrackAppOpened() => Track("app_opened");
    public static void TrackOnboardingStarted() => Track("onboarding_started");
    public static void TrackOnboardingReplayed() => Track("onboarding_replayed");
    public static void TrackOnboardingCompleted() => Track("onboarding_completed");

    public static void TrackPermissionGranted(string permissionName) =>
        Track("permission_granted", ("permission", permissionName));

    public static void TrackAllPermissionsGranted() => Track("all_permissions_granted");

    public static void TrackPermissionDenied(string permissionName) =>
        Track("permission_denied", ("permission", permissionName));

    public static void TrackPushToTalkStarted() => Track("push_to_talk_started");
    public static void TrackPushToTalkReleased() => Track("push_to_talk_released");

    public static void TrackUserMessageSent(string transcript) =>
        Track("user_message_sent",
            ("transcript", transcript),
            ("character_count", transcript.Length));

    public static void TrackAiResponseReceived(string responseText, string modelId) =>
        Track("ai_response_received",
            ("response_text", responseText),
            ("character_count", responseText.Length),
            ("model", modelId));

    public static void TrackElementPointed(string? elementLabel, int? screenNumber) =>
        Track("element_pointed",
            ("element_label", elementLabel ?? string.Empty),
            ("screen_number", screenNumber ?? 1));

    public static void TrackResponseError(string errorMessage) =>
        Track("response_error", ("error", errorMessage));

    public static void TrackTtsError(string errorMessage) =>
        Track("tts_error", ("error", errorMessage));

    // ---- Core capture ----

    private static void Track(string eventName, params (string Key, object? Value)[] extraProperties)
    {
        if (!_isEnabled || _httpClient is null || _distinctId is null) return;

        var properties = new Dictionary<string, object?>
        {
            ["$os"] = "Windows",
            ["$os_version"] = Environment.OSVersion.Version.ToString(),
            ["app_version"] = _appVersion ?? "unknown",
            ["platform"] = "windows",
        };
        foreach (var (key, value) in extraProperties)
        {
            properties[key] = value;
        }

        var payload = new
        {
            api_key = WorkerConfig.PostHogWriteKey,
            @event = eventName,
            distinct_id = _distinctId,
            properties,
            timestamp = DateTimeOffset.UtcNow.ToString("o"),
        };

        // Fire-and-forget. Log failures to debug output only — analytics
        // must not surface errors to the user or break the flow.
        _ = Task.Run(async () =>
        {
            try
            {
                var json = JsonSerializer.Serialize(payload, JsonOptions);
                using var content = new StringContent(json, Encoding.UTF8, "application/json");
                using var response = await _httpClient.PostAsync(WorkerConfig.PostHogCaptureUrl, content)
                    .ConfigureAwait(false);
                // Don't throw on non-success; PostHog returns 200 with an
                // error body when rate-limited or misconfigured.
            }
            catch (Exception ex)
            {
                Debug.WriteLine($"[ClickyAnalytics] capture failed: {ex.Message}");
            }
        });
    }
}
