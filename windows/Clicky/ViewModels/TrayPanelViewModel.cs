using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using System.Collections.ObjectModel;
using Clicky.Services;

namespace Clicky.ViewModels;

/// <summary>
/// View-model for the borderless tray popover. Binds the model picker rows
/// (Claude: Sonnet/Opus, Gemini: Flash/Pro) to <see cref="AppState.SelectedModelId"/>
/// and exposes Quit, onboarding, and privacy-settings commands for the app.
/// </summary>
public sealed partial class TrayPanelViewModel : ObservableObject
{
    private readonly AppState _appState;

    public TrayPanelViewModel(AppState appState)
    {
        _appState = appState;
        _appState.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(AppState.SelectedModelId))
            {
                // Refresh the IsSelected flag on every model option so the
                // segmented-control highlight follows the active choice.
                foreach (var option in ClaudeOptions) option.RefreshSelection(_appState.SelectedModelId);
                foreach (var option in GeminiOptions) option.RefreshSelection(_appState.SelectedModelId);
            }
            else if (args.PropertyName == nameof(AppState.HasCompletedOnboarding))
            {
                OnPropertyChanged(nameof(IsOnboardingVisible));
                OnPropertyChanged(nameof(IsMainContentVisible));
            }
        };

        ClaudeOptions = new ObservableCollection<ModelOption>
        {
            CreateOption("Sonnet", "claude-sonnet-4-6"),
            CreateOption("Opus",   "claude-opus-4-6"),
        };

        GeminiOptions = new ObservableCollection<ModelOption>
        {
            CreateOption("Flash", "gemini-2.5-flash"),
            CreateOption("Pro",   "gemini-2.5-pro"),
        };
    }

    /// <summary>
    /// Shows the welcome/onboarding block (Get started button + intro copy)
    /// until the user completes it once. After that it stays hidden and the
    /// regular panel body takes over.
    /// </summary>
    public bool IsOnboardingVisible => !_appState.HasCompletedOnboarding;

    /// <summary>The main panel body (transcript, model picker, footer) —
    /// shown once onboarding is done.</summary>
    public bool IsMainContentVisible => _appState.HasCompletedOnboarding;

    [RelayCommand]
    private void CompleteOnboarding()
    {
        _appState.HasCompletedOnboarding = true;
        ClickyAnalytics.TrackOnboardingCompleted();
    }

    [RelayCommand]
    private void ReplayOnboarding()
    {
        _appState.HasCompletedOnboarding = false;
        ClickyAnalytics.TrackOnboardingReplayed();
    }

    [RelayCommand]
    private void OpenMicrophonePrivacySettings()
    {
        MicrophonePermissionHelper.OpenWindowsMicrophonePrivacySettings();
    }

    public ObservableCollection<ModelOption> ClaudeOptions { get; }
    public ObservableCollection<ModelOption> GeminiOptions { get; }

    /// <summary>
    /// Exposed so the panel can bind directly to
    /// <see cref="AppState.LiveTranscript"/>,
    /// <see cref="AppState.StreamedResponseText"/>, and
    /// <see cref="AppState.LastStatusMessage"/> without the view-model
    /// having to re-publish them.
    /// </summary>
    public AppState AppState => _appState;

    [RelayCommand]
    private void SelectModel(string modelId)
    {
        if (!string.IsNullOrEmpty(modelId))
        {
            _appState.SelectedModelId = modelId;
        }
    }

    [RelayCommand]
    private void Quit()
    {
        System.Windows.Application.Current.Shutdown();
    }

    private ModelOption CreateOption(string displayLabel, string modelId)
    {
        var option = new ModelOption(displayLabel, modelId, SelectModelCommand);
        option.RefreshSelection(_appState.SelectedModelId);
        return option;
    }
}

/// <summary>
/// A single button within a model-picker segmented control. Exposes a
/// pre-bound <see cref="SelectCommand"/> so the XAML ItemsControl can wire
/// each button without needing ancestor-lookup gymnastics.
/// </summary>
public sealed partial class ModelOption : ObservableObject
{
    public ModelOption(string displayLabel, string modelId, IRelayCommand<string?> selectCommand)
    {
        DisplayLabel = displayLabel;
        ModelId = modelId;
        SelectCommand = selectCommand;
    }

    public string DisplayLabel { get; }
    public string ModelId { get; }
    public IRelayCommand<string?> SelectCommand { get; }

    [ObservableProperty]
    private bool _isSelected;

    public void RefreshSelection(string currentModelId)
    {
        IsSelected = string.Equals(currentModelId, ModelId, StringComparison.OrdinalIgnoreCase);
    }
}
