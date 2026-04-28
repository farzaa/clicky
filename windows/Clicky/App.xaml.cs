using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using H.NotifyIcon;
using Clicky.Interop;
using Clicky.Services;
using Clicky.ViewModels;
using Clicky.Views;

namespace Clicky;

/// <summary>
/// WPF application entry. Boots the tray icon, wires the popover panel,
/// installs the global push-to-talk hotkey, and holds the root AppState
/// for the app's lifetime.
///
/// This is the Windows analog of the macOS CompanionAppDelegate +
/// MenuBarPanelManager combination (leanring_buddyApp.swift + MenuBarPanelManager.swift).
/// </summary>
public partial class App : Application
{
    // Keep singletons alive for the app's lifetime. No DI container in M1 —
    // the dependency graph is small enough to thread manually.
    private Mutex? _singleInstanceMutex;
    private SettingsService? _settingsService;
    private AppState? _appState;
    private GlobalHotkeyService? _globalHotkeyService;
    private TaskbarIcon? _trayIcon;
    private TrayPanelWindow? _trayPanelWindow;
    private TrayPanelViewModel? _trayPanelViewModel;
    private VoicePipelineOrchestrator? _voicePipelineOrchestrator;
    private OverlayWindowManager? _overlayWindowManager;

    protected override void OnStartup(StartupEventArgs eventArgs)
    {
        base.OnStartup(eventArgs);

        if (!TryAcquireSingleInstanceMutex())
        {
            // Another instance is already running. Exit quietly — no error
            // dialog, so double-clicks from the Start menu are benign.
            Shutdown();
            return;
        }

        _settingsService = new SettingsService();
        _appState = new AppState(_settingsService);
        _trayPanelViewModel = new TrayPanelViewModel(_appState);
        _trayPanelWindow = new TrayPanelWindow(_trayPanelViewModel);

        // PostHog setup — idempotent, silent no-op until the write key in
        // WorkerConfig.cs is replaced with a real project key. Fires
        // app_opened on success.
        ClickyAnalytics.Configure(_settingsService.AnalyticsDistinctId);

        InstallTrayIcon();
        InstallGlobalHotkey();

        // The overlay windows are created after the tray is up so nothing
        // flashes in an uninitialized state. Transparent + click-through, so
        // their presence is invisible to the desktop beneath. The voice
        // pipeline takes a reference so the [POINT:…] tag on each reply can
        // fire an element-pointing flight before TTS speaks the text.
        _overlayWindowManager = new OverlayWindowManager(_appState, Dispatcher);
        _overlayWindowManager.Start();

        _voicePipelineOrchestrator = new VoicePipelineOrchestrator(_appState, Dispatcher, _overlayWindowManager);

        // First-run onboarding: if the user hasn't completed it, auto-open
        // the panel on a centered position so the very first launch shows
        // the welcome copy instead of a silent tray icon. Also probe the
        // microphone so a disabled capture endpoint is surfaced before the
        // first push-to-talk attempt.
        ProbeMicrophoneAvailabilityAndUpdateState();
        if (!_appState.HasCompletedOnboarding)
        {
            _trayPanelWindow.ShowPanelCenteredOnPrimaryScreen();
            ClickyAnalytics.TrackOnboardingStarted();
        }
    }

    private void ProbeMicrophoneAvailabilityAndUpdateState()
    {
        if (_appState is null) return;
        var hasMic = MicrophonePermissionHelper.HasActiveCaptureDevice();
        _appState.IsMicrophonePermissionIssue = !hasMic;
        if (!hasMic)
        {
            _appState.LastStatusMessage =
                "Microphone appears to be off or blocked. Open Windows privacy settings to enable it.";
            ClickyAnalytics.TrackPermissionDenied("microphone");
        }
        else
        {
            ClickyAnalytics.TrackPermissionGranted("microphone");
        }
    }

    protected override void OnExit(ExitEventArgs eventArgs)
    {
        _overlayWindowManager?.Dispose();
        _globalHotkeyService?.Dispose();
        _trayIcon?.Dispose();
        // Orchestrator owns mic/websocket/TTS — dispose synchronously so
        // their background threads are joined before the process exits.
        if (_voicePipelineOrchestrator is not null)
        {
            _voicePipelineOrchestrator.DisposeAsync().AsTask().GetAwaiter().GetResult();
        }
        _singleInstanceMutex?.ReleaseMutex();
        _singleInstanceMutex?.Dispose();
        base.OnExit(eventArgs);
    }

    private bool TryAcquireSingleInstanceMutex()
    {
        // Per-user mutex — two different users on the same machine can each
        // run their own Clicky instance without colliding.
        var mutexName = $"Local\\Clicky.SingleInstance.{Environment.UserName}";
        _singleInstanceMutex = new Mutex(initiallyOwned: true, name: mutexName, createdNew: out var createdNew);
        return createdNew;
    }

    private void InstallTrayIcon()
    {
        // H.NotifyIcon's IconSource (ImageSource) path can't reliably consume
        // a programmatically-rendered bitmap (it tries to round-trip via a
        // BitmapImage.UriSource it never has). The Icon property accepts a
        // System.Drawing.Icon directly and bypasses that whole conversion,
        // so we generate or load a real Win32 icon instead.
        _trayIcon = new TaskbarIcon
        {
            ToolTipText = "Clicky - hold Ctrl+Alt to talk",
            Icon = LoadTrayIcon(),
            // No built-in context menu - left- and right-click both open the
            // custom popover. Quit lives inside the panel.
            NoLeftClickDelay = true,
        };

        _trayIcon.TrayLeftMouseUp += (_, _) => ToggleTrayPanel();
        _trayIcon.TrayRightMouseUp += (_, _) => ToggleTrayPanel();

        _trayIcon.ForceCreate();
    }

    private void InstallGlobalHotkey()
    {
        _globalHotkeyService = new GlobalHotkeyService();
        _globalHotkeyService.ShortcutPressed += OnPushToTalkPressed;
        _globalHotkeyService.ShortcutReleased += OnPushToTalkReleased;
        _globalHotkeyService.Start();
    }

    private void OnPushToTalkPressed(object? sender, EventArgs eventArgs)
    {
        // Panel shouldn't stay visible while the user is talking to the
        // app — dismiss it if it happens to be open.
        Dispatcher.BeginInvoke(() => _trayPanelWindow?.HidePanel());

        // The orchestrator owns the state transitions (Listening / Processing
        // / Responding / Idle) from here. Swallow exceptions — the
        // orchestrator reports them via AppState.LastStatusMessage.
        _ = _voicePipelineOrchestrator?.HandlePushToTalkPressedAsync();
    }

    private void OnPushToTalkReleased(object? sender, EventArgs eventArgs)
    {
        _ = _voicePipelineOrchestrator?.HandlePushToTalkReleasedAsync();
    }

    private void ToggleTrayPanel()
    {
        if (_trayPanelWindow is null) return;

        if (_trayPanelWindow.IsVisible)
        {
            _trayPanelWindow.HidePanel();
            return;
        }

        NativeMethods.GetCursorPos(out var cursorPositionDevicePixels);
        _trayPanelWindow.ShowNearTrayCursor(
            cursorPositionDevicePixels.X,
            cursorPositionDevicePixels.Y);
    }

    /// <summary>
    /// Loads the tray icon from the bundled resource. Falls back to a
    /// generated blue-dot placeholder if the resource is missing so the app
    /// is runnable before an artist drops a real .ico in.
    /// </summary>
    private static System.Drawing.Icon LoadTrayIcon()
    {
        try
        {
            var packIconUri = new Uri("pack://application:,,,/Resources/clicky-tray.ico", UriKind.Absolute);
            var packResource = GetResourceStream(packIconUri);
            if (packResource?.Stream is not null)
            {
                using var iconStream = packResource.Stream;
                return new System.Drawing.Icon(iconStream);
            }
        }
        catch
        {
            // Fall through to the generated placeholder.
        }

        return CreatePlaceholderBlueDotIcon();
    }

    /// <summary>
    /// Builds a 32x32 transparent-background blue dot Icon using GDI so
    /// H.NotifyIcon can take it directly. Used when no real clicky-tray.ico
    /// resource has been bundled.
    /// </summary>
    private static System.Drawing.Icon CreatePlaceholderBlueDotIcon()
    {
        const int iconPixelSize = 32;
        const int iconPadding = 6;

        using var bitmap = new System.Drawing.Bitmap(
            iconPixelSize,
            iconPixelSize,
            System.Drawing.Imaging.PixelFormat.Format32bppArgb);

        using (var graphics = System.Drawing.Graphics.FromImage(bitmap))
        {
            graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            graphics.Clear(System.Drawing.Color.Transparent);

            using var overlayCursorBlueBrush = new System.Drawing.SolidBrush(
                System.Drawing.Color.FromArgb(0xFF, 0x33, 0x80, 0xFF));

            graphics.FillEllipse(
                overlayCursorBlueBrush,
                iconPadding,
                iconPadding,
                iconPixelSize - (iconPadding * 2),
                iconPixelSize - (iconPadding * 2));
        }

        // GetHicon hands ownership of the HICON to us; FromHandle doesn't take
        // ownership, so we'd normally have to clean it up. The TaskbarIcon
        // keeps this Icon for the lifetime of the app, so the leak is bounded
        // to a single 32x32 cursor handle.
        var hIcon = bitmap.GetHicon();
        return (System.Drawing.Icon)System.Drawing.Icon.FromHandle(hIcon).Clone();
    }
}
