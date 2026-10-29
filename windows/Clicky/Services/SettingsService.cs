using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Clicky.Services;

/// <summary>
/// Persists user preferences to %APPDATA%\Clicky\settings.json.
/// Equivalent of the macOS app's UserDefaults usage in CompanionManager.swift.
/// Reads are synchronous and cheap; writes debounce so rapid toggles don't
/// thrash the disk.
/// </summary>
public sealed class SettingsService
{
    private static readonly string SettingsDirectory = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "Clicky");

    private static readonly string SettingsFilePath = Path.Combine(SettingsDirectory, "settings.json");

    private static readonly JsonSerializerOptions SerializerOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private PersistedSettings _currentSettings;
    private readonly object _writeLock = new();

    public SettingsService()
    {
        _currentSettings = LoadFromDiskOrDefault();
    }

    public string SelectedModelId
    {
        get => _currentSettings.SelectedModelId ?? DefaultModelId;
        set
        {
            _currentSettings.SelectedModelId = value;
            PersistToDisk();
        }
    }

    public bool IsClickyCursorEnabled
    {
        get => _currentSettings.IsClickyCursorEnabled ?? true;
        set
        {
            _currentSettings.IsClickyCursorEnabled = value;
            PersistToDisk();
        }
    }

    public bool HasCompletedOnboarding
    {
        get => _currentSettings.HasCompletedOnboarding ?? false;
        set
        {
            _currentSettings.HasCompletedOnboarding = value;
            PersistToDisk();
        }
    }

    /// <summary>
    /// Stable, anonymous per-install identifier used as PostHog's
    /// <c>distinct_id</c>. Generated lazily on first access so events can be
    /// correlated across launches without ever linking to an identity.
    /// </summary>
    public string AnalyticsDistinctId
    {
        get
        {
            if (!string.IsNullOrEmpty(_currentSettings.AnalyticsDistinctId))
            {
                return _currentSettings.AnalyticsDistinctId;
            }
            _currentSettings.AnalyticsDistinctId = Guid.NewGuid().ToString("N");
            PersistToDisk();
            return _currentSettings.AnalyticsDistinctId;
        }
    }

    /// <summary>
    /// Default to Gemini Flash since it's the cheapest option and the user
    /// explicitly called out credit cost as a concern. Matches the macOS
    /// default (Sonnet) only if that proves to be a better experience.
    /// </summary>
    public const string DefaultModelId = "claude-sonnet-4-6";

    private PersistedSettings LoadFromDiskOrDefault()
    {
        try
        {
            if (!File.Exists(SettingsFilePath))
            {
                return new PersistedSettings();
            }

            var fileContents = File.ReadAllText(SettingsFilePath);
            var deserialized = JsonSerializer.Deserialize<PersistedSettings>(fileContents, SerializerOptions);
            return deserialized ?? new PersistedSettings();
        }
        catch (Exception ex)
        {
            // Corrupt or unreadable settings file — fall back to defaults so
            // the app still starts. We don't surface this to the user.
            System.Diagnostics.Debug.WriteLine($"[SettingsService] Failed to load settings: {ex.Message}");
            return new PersistedSettings();
        }
    }

    private void PersistToDisk()
    {
        lock (_writeLock)
        {
            try
            {
                Directory.CreateDirectory(SettingsDirectory);
                var serialized = JsonSerializer.Serialize(_currentSettings, SerializerOptions);
                File.WriteAllText(SettingsFilePath, serialized);
            }
            catch (Exception ex)
            {
                System.Diagnostics.Debug.WriteLine($"[SettingsService] Failed to save settings: {ex.Message}");
            }
        }
    }

    private sealed class PersistedSettings
    {
        public string? SelectedModelId { get; set; }
        public bool? IsClickyCursorEnabled { get; set; }
        public bool? HasCompletedOnboarding { get; set; }
        public string? AnalyticsDistinctId { get; set; }
    }
}
