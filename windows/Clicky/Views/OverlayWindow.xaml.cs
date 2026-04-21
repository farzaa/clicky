using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using Clicky.Interop;

namespace Clicky.Views;

/// <summary>
/// Transparent, click-through, always-on-top overlay covering a single
/// monitor. Renders the blue triangle cursor that follows the system mouse.
///
/// One instance is created per connected display; the
/// <see cref="Services.OverlayWindowManager"/> owns their lifecycle and
/// drives cursor updates at 60 fps.
///
/// Mirrors the macOS <c>OverlayWindow</c> in <c>OverlayWindow.swift</c>.
/// </summary>
public partial class OverlayWindow : Window
{
    // Cursor-to-triangle offset matches the macOS overlay (35 px right,
    // 25 px down) so the triangle sits beside the system cursor rather
    // than on top of it. Interpreted in DIPs.
    private const double CursorOffsetDipX = 35;
    private const double CursorOffsetDipY = 25;

    // The three polygon vertices live in a 16-DIP bounding box; the
    // RotateTransform origin is (0.5, 0.3333) which puts the pivot at the
    // centroid. When we move the triangle we place that centroid at the
    // target position, so these constants shift the Canvas.Left/Top.
    private const double TriangleBoundingBoxDipWidth = 16.0;
    private const double TriangleBoundingBoxDipHeight = 13.856;
    private const double TriangleCentroidOffsetDipX = TriangleBoundingBoxDipWidth / 2.0;
    private const double TriangleCentroidOffsetDipY = TriangleBoundingBoxDipHeight / 3.0;

    private readonly int _monitorBoundsLeftDevicePixels;
    private readonly int _monitorBoundsTopDevicePixels;
    private readonly int _monitorWidthDevicePixels;
    private readonly int _monitorHeightDevicePixels;

    private bool _hasBeenPositioned;

    public OverlayWindow(
        int monitorBoundsLeftDevicePixels,
        int monitorBoundsTopDevicePixels,
        int monitorWidthDevicePixels,
        int monitorHeightDevicePixels)
    {
        _monitorBoundsLeftDevicePixels = monitorBoundsLeftDevicePixels;
        _monitorBoundsTopDevicePixels = monitorBoundsTopDevicePixels;
        _monitorWidthDevicePixels = monitorWidthDevicePixels;
        _monitorHeightDevicePixels = monitorHeightDevicePixels;

        InitializeComponent();
        SourceInitialized += ApplyClickThroughExtendedStyles;
    }

    /// <summary>
    /// Called once during startup by <see cref="Services.OverlayWindowManager"/>.
    /// Applies click-through window styles and positions the overlay over
    /// the monitor in device-pixel coordinates.
    /// </summary>
    public void ShowOnMonitor()
    {
        // Ensure the HWND exists — required before SetWindowPos and before
        // the style bits get applied by <see cref="ApplyClickThroughExtendedStyles"/>.
        var windowHandle = new WindowInteropHelper(this).EnsureHandle();

        NativeMethods.SetWindowPos(
            windowHandle,
            NativeMethods.HWND_TOPMOST,
            _monitorBoundsLeftDevicePixels,
            _monitorBoundsTopDevicePixels,
            _monitorWidthDevicePixels,
            _monitorHeightDevicePixels,
            NativeMethods.SWP_NOACTIVATE | NativeMethods.SWP_SHOWWINDOW);

        Visibility = Visibility.Visible;
        _hasBeenPositioned = true;
    }

    /// <summary>
    /// Updates the overlay's triangle for a single cursor tracker tick.
    /// When <paramref name="cursorIsOnThisMonitor"/> is false, we hide the
    /// triangle so only one overlay shows it at a time.
    /// </summary>
    public void UpdateCursorState(
        int cursorGlobalDeviceX,
        int cursorGlobalDeviceY,
        bool cursorIsOnThisMonitor,
        bool triangleShouldBeVisible)
    {
        if (!_hasBeenPositioned) return;

        if (!cursorIsOnThisMonitor || !triangleShouldBeVisible)
        {
            if (BlueTriangle.Visibility != Visibility.Collapsed)
            {
                BlueTriangle.Visibility = Visibility.Collapsed;
            }
            return;
        }

        // Convert the global cursor position (device pixels) into this
        // monitor's local space, then into DIPs using the window's DPI so
        // the triangle lands at the right spot on a scaled display.
        var dpiScale = NativeMethods.GetDpiScale(this);
        if (dpiScale <= 0) dpiScale = 1.0;

        var cursorLocalDeviceX = cursorGlobalDeviceX - _monitorBoundsLeftDevicePixels;
        var cursorLocalDeviceY = cursorGlobalDeviceY - _monitorBoundsTopDevicePixels;

        var cursorLocalDipX = cursorLocalDeviceX / dpiScale;
        var cursorLocalDipY = cursorLocalDeviceY / dpiScale;

        // The triangle's RenderTransformOrigin is (0.5, 1/3), so we offset
        // the Canvas.Left/Top by the centroid offsets to put the triangle's
        // centroid exactly at (cursor + offset).
        var triangleAnchorDipX = cursorLocalDipX + CursorOffsetDipX;
        var triangleAnchorDipY = cursorLocalDipY + CursorOffsetDipY;

        Canvas.SetLeft(BlueTriangle, triangleAnchorDipX - TriangleCentroidOffsetDipX);
        Canvas.SetTop(BlueTriangle, triangleAnchorDipY - TriangleCentroidOffsetDipY);

        if (BlueTriangle.Visibility != Visibility.Visible)
        {
            BlueTriangle.Visibility = Visibility.Visible;
        }
    }

    private static void ApplyClickThroughExtendedStyles(object? sender, EventArgs eventArgs)
    {
        if (sender is not OverlayWindow overlayWindow) return;

        var windowHandle = new WindowInteropHelper(overlayWindow).Handle;
        var currentExtendedStyle = NativeMethods.GetExtendedStyle(windowHandle);
        // WS_EX_TRANSPARENT  — forwards mouse events to the window beneath
        // WS_EX_LAYERED      — required for WS_EX_TRANSPARENT on a non-child
        // WS_EX_NOACTIVATE   — clicking the overlay never steals focus
        // WS_EX_TOOLWINDOW   — never appears in Alt+Tab / taskbar
        var desiredExtendedStyle = currentExtendedStyle
            | NativeMethods.WS_EX_TRANSPARENT
            | NativeMethods.WS_EX_LAYERED
            | NativeMethods.WS_EX_NOACTIVATE
            | NativeMethods.WS_EX_TOOLWINDOW;
        NativeMethods.SetExtendedStyle(windowHandle, desiredExtendedStyle);
    }
}
