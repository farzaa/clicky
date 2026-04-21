using System.Windows;
using System.Windows.Interop;
using Clicky.Interop;
using Clicky.ViewModels;

namespace Clicky.Views;

/// <summary>
/// Borderless popover hosted over the system tray. Matches the macOS floating
/// NSPanel: non-activating, click-outside dismissal, drop shadow, rounded
/// corners. Shown on demand by <see cref="App"/> when the tray icon is clicked.
/// </summary>
public partial class TrayPanelWindow : Window
{
    public TrayPanelWindow(TrayPanelViewModel viewModel)
    {
        DataContext = viewModel;
        InitializeComponent();

        SourceInitialized += ApplyNonActivatingExtendedStyles;
        Deactivated += HideOnDeactivate;
    }

    /// <summary>
    /// Positions the panel above the taskbar tray area and shows it without
    /// stealing focus. The cursor-position argument is typically the point
    /// where the user clicked the tray icon — it's used to horizontally align
    /// the panel near the icon.
    /// </summary>
    public void ShowNearTrayCursor(double cursorScreenX, double cursorScreenY)
    {
        var windowHandle = new WindowInteropHelper(this).EnsureHandle();
        var taskbarRect = ReadTaskbarRectOrFallback(cursorScreenX, cursorScreenY);
        var dpiScale = NativeMethods.GetDpiScale(this);

        Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var desiredPanelSize = DesiredSize;
        var panelWidthInDeviceUnits = desiredPanelSize.Width * dpiScale;
        var panelHeightInDeviceUnits = desiredPanelSize.Height * dpiScale;

        // Anchor horizontally to the cursor, clamped so the full panel stays
        // on the same monitor as the tray click.
        var panelLeftDevice = cursorScreenX - (panelWidthInDeviceUnits / 2);
        var panelTopDevice = taskbarRect.Top - panelHeightInDeviceUnits - 4;

        if (panelLeftDevice < taskbarRect.Left)
        {
            panelLeftDevice = taskbarRect.Left;
        }
        if (panelLeftDevice + panelWidthInDeviceUnits > taskbarRect.Right)
        {
            panelLeftDevice = taskbarRect.Right - panelWidthInDeviceUnits;
        }

        // If the taskbar is at the top of the screen, flip the panel below it
        // instead of placing it above (would be off-screen).
        if (panelTopDevice < 0)
        {
            panelTopDevice = taskbarRect.Bottom + 4;
        }

        NativeMethods.SetWindowPos(
            windowHandle,
            NativeMethods.HWND_TOPMOST,
            (int)panelLeftDevice,
            (int)panelTopDevice,
            (int)panelWidthInDeviceUnits,
            (int)panelHeightInDeviceUnits,
            NativeMethods.SWP_NOACTIVATE | NativeMethods.SWP_SHOWWINDOW);

        // Don't call Show() — that would activate the window. SetWindowPos
        // with SWP_SHOWWINDOW + SWP_NOACTIVATE is the right incantation.
        Visibility = Visibility.Visible;
    }

    public void HidePanel()
    {
        if (IsVisible)
        {
            Hide();
        }
    }

    private void ApplyNonActivatingExtendedStyles(object? sender, EventArgs eventArgs)
    {
        var windowHandle = new WindowInteropHelper(this).Handle;
        var currentExtendedStyle = NativeMethods.GetExtendedStyle(windowHandle);
        // Add WS_EX_TOOLWINDOW so the panel never shows in the Alt+Tab list,
        // and WS_EX_NOACTIVATE so clicking inside it doesn't steal focus
        // from whatever the user was working in. This mirrors the macOS
        // "nonactivating" NSPanel behavior.
        var desiredExtendedStyle = currentExtendedStyle
            | NativeMethods.WS_EX_TOOLWINDOW
            | NativeMethods.WS_EX_NOACTIVATE;
        NativeMethods.SetExtendedStyle(windowHandle, desiredExtendedStyle);
    }

    private void HideOnDeactivate(object? sender, EventArgs eventArgs)
    {
        // Clicking anywhere outside the panel fires Deactivated. Hiding here
        // gives us click-outside-to-dismiss without installing a global
        // mouse hook.
        HidePanel();
    }

    /// <summary>
    /// Returns the taskbar bounds via SHAppBarMessage. If the query fails
    /// (rare — mostly on remote desktop sessions), falls back to the primary
    /// screen's working area bottom edge at the cursor's screen.
    /// </summary>
    private static NativeMethods.RECT ReadTaskbarRectOrFallback(double cursorScreenX, double cursorScreenY)
    {
        var appBarData = new NativeMethods.APPBARDATA
        {
            cbSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<NativeMethods.APPBARDATA>(),
        };

        var queryResult = NativeMethods.SHAppBarMessage(NativeMethods.ABM_GETTASKBARPOS, ref appBarData);
        if (queryResult != IntPtr.Zero)
        {
            return appBarData.rc;
        }

        return new NativeMethods.RECT
        {
            Left = (int)(cursorScreenX - 200),
            Top = (int)(cursorScreenY - 4),
            Right = (int)(cursorScreenX + 200),
            Bottom = (int)cursorScreenY,
        };
    }
}
