using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows;
using System.Windows.Controls;
using Hardcodet.Wpf.TaskbarNotification;

namespace Clicky.App;

/// <summary>
/// Manages the system tray icon, context menu, and left-click events.
/// Mirrors the Mac MenuBarPanelManager status item behavior.
/// </summary>
public sealed class TrayIconManager : IDisposable
{
    private readonly TaskbarIcon _trayIcon;
    private bool _disposed;

    /// <summary>
    /// Raised when the user left-clicks the tray icon.
    /// The Companion layer subscribes to this to toggle the control panel.
    /// </summary>
    public event EventHandler? TrayIconClicked;

    public TrayIconManager()
    {
        _trayIcon = new TaskbarIcon
        {
            Icon = CreateDefaultIcon(),
            ToolTipText = "Clicky",
            ContextMenu = BuildContextMenu(),
        };

        _trayIcon.TrayLeftMouseUp += OnTrayLeftClick;
    }

    private void OnTrayLeftClick(object sender, RoutedEventArgs e)
    {
        TrayIconClicked?.Invoke(this, EventArgs.Empty);
    }

    private static ContextMenu BuildContextMenu()
    {
        var menu = new ContextMenu();

        var openItem = new MenuItem { Header = "Open" };
        openItem.Click += (_, _) =>
        {
            // Placeholder: will be wired to show the companion panel in US-003.
        };

        var quitItem = new MenuItem { Header = "Quit" };
        quitItem.Click += (_, _) => Application.Current.Shutdown();

        menu.Items.Add(openItem);
        menu.Items.Add(new Separator());
        menu.Items.Add(quitItem);

        return menu;
    }

    /// <summary>
    /// Creates a simple blue triangle icon matching the Clicky branding.
    /// </summary>
    private static Icon CreateDefaultIcon()
    {
        const int size = 32;
        using var bitmap = new Bitmap(size, size);
        using var g = Graphics.FromImage(bitmap);

        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Color.Transparent);

        // Blue triangle cursor shape
        var points = new[]
        {
            new PointF(6, 4),
            new PointF(6, 28),
            new PointF(26, 16),
        };

        using var brush = new SolidBrush(Color.FromArgb(255, 59, 130, 246));
        g.FillPolygon(brush, points);

        return System.Drawing.Icon.FromHandle(bitmap.GetHicon());
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        _trayIcon.TrayLeftMouseUp -= OnTrayLeftClick;
        _trayIcon.Dispose();
    }
}
