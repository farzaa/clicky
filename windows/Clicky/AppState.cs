using CommunityToolkit.Mvvm.ComponentModel;
using Clicky.Services;

namespace Clicky;

/// <summary>
/// Root observable state for the entire Windows app. The C# analog of the
/// macOS CompanionManager (leanring-buddy/CompanionManager.swift). Milestone 1
/// holds only the persisted preferences and the voice-state enum; later
/// milestones attach the screen-capture, dictation, and AI-chat services.
/// </summary>
public sealed partial class AppState : ObservableObject
{
    private readonly SettingsService _settingsService;

    public AppState(SettingsService settingsService)
    {
        _settingsService = settingsService;
        _selectedModelId = settingsService.SelectedModelId;
        _isClickyCursorEnabled = settingsService.IsClickyCursorEnabled;
        _hasCompletedOnboarding = settingsService.HasCompletedOnboarding;
    }

    // ---- Voice pipeline state (populated by later milestones) ----

    public enum VoiceState
    {
        Idle,
        Listening,
        Processing,
        Responding,
    }

    [ObservableProperty]
    private VoiceState _currentVoiceState = VoiceState.Idle;

    // ---- Persisted preferences ----

    [ObservableProperty]
    private string _selectedModelId;

    partial void OnSelectedModelIdChanged(string value)
    {
        _settingsService.SelectedModelId = value;
    }

    [ObservableProperty]
    private bool _isClickyCursorEnabled;

    partial void OnIsClickyCursorEnabledChanged(bool value)
    {
        _settingsService.IsClickyCursorEnabled = value;
    }

    [ObservableProperty]
    private bool _hasCompletedOnboarding;

    partial void OnHasCompletedOnboardingChanged(bool value)
    {
        _settingsService.HasCompletedOnboarding = value;
    }

    // ---- Model routing helpers (mirror CompanionManager.isGeminiModelID) ----

    /// <summary>
    /// Returns true when the given model ID belongs to the Gemini provider.
    /// Used by later milestones to route vision requests to the right client.
    /// </summary>
    public static bool IsGeminiModelId(string modelId) => modelId.StartsWith("gemini", StringComparison.OrdinalIgnoreCase);

    public bool IsCurrentModelGemini => IsGeminiModelId(SelectedModelId);
}
