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

        InstallTrayIcon();
        InstallGlobalHotkey();
    }

    protected override void OnExit(ExitEventArgs eventArgs)
    {
        _globalHotkeyService?.Dispose();
        _trayIcon?.Dispose();
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
        _trayIcon = new TaskbarIcon
        {
            ToolTipText = "Clicky — hold Ctrl+Alt to talk",
            IconSource = LoadTrayIconSource(),
            // No built-in context menu — left- and right-click both open the
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
        // Milestone 2 wires this to the dictation pipeline. For now we just
        // flip the state so the panel can reflect it and we can verify the
        // hook is detecting the combo.
        Dispatcher.BeginInvoke(() =>
        {
            if (_appState is not null)
            {
                _appState.CurrentVoiceState = AppState.VoiceState.Listening;
            }
            // Panel shouldn't stay visible while the user is talking to the
            // app — dismiss it if it happens to be open.
            _trayPanelWindow?.HidePanel();
        });
    }

    private void OnPushToTalkReleased(object? sender, EventArgs eventArgs)
    {
        Dispatcher.BeginInvoke(() =>
        {
            if (_appState is not null)
            {
                _appState.CurrentVoiceState = AppState.VoiceState.Idle;
            }
        });
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
    private static ImageSource LoadTrayIconSource()
    {
        try
        {
            var packIconUri = new Uri("pack://application:,,,/Resources/clicky-tray.ico", UriKind.Absolute);
            var packResource = GetResourceStream(packIconUri);
            if (packResource?.Stream is not null)
            {
                var bundledIconBitmap = new BitmapImage();
                bundledIconBitmap.BeginInit();
                bundledIconBitmap.CacheOption = BitmapCacheOption.OnLoad;
                bundledIconBitmap.StreamSource = packResource.Stream;
                bundledIconBitmap.EndInit();
                bundledIconBitmap.Freeze();
                return bundledIconBitmap;
            }
        }
        catch
        {
            // Fall through to the generated placeholder.
        }

        return CreatePlaceholderBlueDotBitmap();
    }

    private static BitmapSource CreatePlaceholderBlueDotBitmap()
    {
        const int iconPixelSize = 32;
        const int iconPadding = 6;

        var drawingVisual = new DrawingVisual();
        using (var drawingContext = drawingVisual.RenderOpen())
        {
            var overlayCursorBlue = new SolidColorBrush(Color.FromRgb(0x33, 0x80, 0xFF));
            overlayCursorBlue.Freeze();

            var circleCenter = new System.Windows.Point(iconPixelSize / 2.0, iconPixelSize / 2.0);
            var circleRadius = (iconPixelSize - (iconPadding * 2)) / 2.0;

            drawingContext.DrawEllipse(
                brush: overlayCursorBlue,
                pen: null,
                center: circleCenter,
                radiusX: circleRadius,
                radiusY: circleRadius);
        }

        var renderTarget = new RenderTargetBitmap(
            pixelWidth: iconPixelSize,
            pixelHeight: iconPixelSize,
            dpiX: 96,
            dpiY: 96,
            pixelFormat: PixelFormats.Pbgra32);
        renderTarget.Render(drawingVisual);
        renderTarget.Freeze();
        return renderTarget;
    }
}
