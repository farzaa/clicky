using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Clicky.Interop;

namespace Clicky.Services;

/// <summary>
/// Grabs a JPEG of every attached display and returns them ordered with
/// the cursor's display first. Port of the macOS
/// <c>CompanionScreenCaptureUtility.captureAllScreensAsJPEG()</c>.
///
/// Uses GDI BitBlt against the desktop DC — simple, per-monitor-DPI-aware
/// (thanks to PerMonitorV2 in app.manifest), and doesn't require the
/// WinRT <c>Windows.Graphics.Capture</c> picker flow. Acceptable for
/// static snapshots; if we ever need continuous capture we can swap in
/// <c>GraphicsCaptureItem</c> later.
/// </summary>
public sealed class ScreenCaptureService
{
    /// <summary>JPEG encoder quality, matches the macOS client (0.8 → 80%).</summary>
    private const int JpegQualityPercent = 80;

    /// <summary>Longest-side pixel budget. Anything larger is downscaled so
    /// the API request stays well under Anthropic/Gemini inline image
    /// size limits and keeps uploads fast. Matches macOS (1280 points).</summary>
    private const int MaxLongestSidePixels = 1280;

    /// <summary>
    /// Captures every monitor synchronously. Returns a list ordered with
    /// the cursor's monitor first (flagged "primary focus" in the label)
    /// and the rest in enumeration order.
    /// </summary>
    public IReadOnlyList<MonitorCapture> CaptureAllMonitors()
    {
        var enumeratedMonitors = EnumerateMonitors();
        if (enumeratedMonitors.Count == 0)
        {
            return Array.Empty<MonitorCapture>();
        }

        var cursorMonitorHandle = FindCursorMonitorHandle();
        var orderedMonitors = OrderCursorFirst(enumeratedMonitors, cursorMonitorHandle);

        var capturedList = new List<MonitorCapture>(orderedMonitors.Count);
        for (var orderedIndex = 0; orderedIndex < orderedMonitors.Count; orderedIndex++)
        {
            var monitor = orderedMonitors[orderedIndex];
            var humanReadableLabel = BuildMonitorLabel(
                orderedIndex: orderedIndex,
                totalCount: orderedMonitors.Count,
                isCursorMonitor: monitor.HandleEquals(cursorMonitorHandle),
                isPrimaryMonitor: (monitor.Flags & NativeMethods.MONITORINFOF_PRIMARY) != 0);

            var capture = CaptureSingleMonitor(monitor, humanReadableLabel);
            capturedList.Add(capture);
        }
        return capturedList;
    }

    private MonitorCapture CaptureSingleMonitor(EnumeratedMonitor monitor, string humanReadableLabel)
    {
        // 1. Capture raw pixels via GDI BitBlt.
        var sourceBitmap = BitBltMonitorToBitmapSource(monitor);

        // 2. Downscale so the largest side fits MaxLongestSidePixels.
        var downscaledBitmap = DownscaleIfLarger(sourceBitmap, MaxLongestSidePixels);

        // 3. Encode as JPEG at the configured quality.
        var jpegBytes = EncodeAsJpeg(downscaledBitmap, JpegQualityPercent);

        return new MonitorCapture(
            JpegData: jpegBytes,
            MimeType: "image/jpeg",
            Label: humanReadableLabel,
            IsCursorMonitor: monitor.HandleEquals(FindCursorMonitorHandle()),
            DisplayWidthPixels: monitor.PhysicalWidthPixels,
            DisplayHeightPixels: monitor.PhysicalHeightPixels,
            ScreenshotWidthPixels: downscaledBitmap.PixelWidth,
            ScreenshotHeightPixels: downscaledBitmap.PixelHeight,
            DisplayBoundsDevicePixels: new Int32Rect(
                monitor.BoundsLeft, monitor.BoundsTop,
                monitor.PhysicalWidthPixels, monitor.PhysicalHeightPixels));
    }

    /// <summary>
    /// Walks every monitor via EnumDisplayMonitors. The callback gives us
    /// an HMONITOR per display; we turn each into a MONITORINFOEX for the
    /// bounds + device name. Returned in system enumeration order.
    /// </summary>
    private static List<EnumeratedMonitor> EnumerateMonitors()
    {
        var enumeratedList = new List<EnumeratedMonitor>();

        bool MonitorEnumCallback(IntPtr hMonitor, IntPtr hdcMonitor, ref NativeMethods.RECT lprcMonitor, IntPtr dwData)
        {
            var monitorInfo = new NativeMethods.MONITORINFOEX
            {
                cbSize = System.Runtime.InteropServices.Marshal.SizeOf<NativeMethods.MONITORINFOEX>(),
            };
            if (!NativeMethods.GetMonitorInfo(hMonitor, ref monitorInfo))
            {
                // Skip monitors we couldn't query — shouldn't happen in practice.
                return true;
            }

            enumeratedList.Add(new EnumeratedMonitor(
                Handle: hMonitor,
                BoundsLeft: monitorInfo.rcMonitor.Left,
                BoundsTop: monitorInfo.rcMonitor.Top,
                PhysicalWidthPixels: monitorInfo.rcMonitor.Width,
                PhysicalHeightPixels: monitorInfo.rcMonitor.Height,
                Flags: monitorInfo.dwFlags,
                DeviceName: monitorInfo.szDevice ?? string.Empty));
            return true;
        }

        NativeMethods.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, MonitorEnumCallback, IntPtr.Zero);
        return enumeratedList;
    }

    private static IntPtr FindCursorMonitorHandle()
    {
        if (!NativeMethods.GetCursorPos(out var cursorPosition))
        {
            return IntPtr.Zero;
        }
        return NativeMethods.MonitorFromPoint(cursorPosition, NativeMethods.MONITOR_DEFAULTTONEAREST);
    }

    /// <summary>Moves the cursor monitor to index 0; preserves the rest in
    /// original order. Mirrors the macOS ordering so the AI prompt places
    /// the "primary focus" screen first.</summary>
    private static List<EnumeratedMonitor> OrderCursorFirst(
        IReadOnlyList<EnumeratedMonitor> sourceMonitors,
        IntPtr cursorMonitorHandle)
    {
        var orderedList = new List<EnumeratedMonitor>(sourceMonitors.Count);
        EnumeratedMonitor? cursorMonitor = null;
        foreach (var monitor in sourceMonitors)
        {
            if (monitor.HandleEquals(cursorMonitorHandle)) { cursorMonitor = monitor; }
            else { orderedList.Add(monitor); }
        }
        if (cursorMonitor is not null)
        {
            orderedList.Insert(0, cursorMonitor);
        }
        return orderedList;
    }

    /// <summary>
    /// Copies a monitor's pixels into a WPF-consumable BitmapSource via
    /// GDI BitBlt. We operate on the desktop DC so the coordinates are
    /// virtual-screen coordinates (matches what GetMonitorInfo returns
    /// under PerMonitorV2 DPI awareness).
    /// </summary>
    private static BitmapSource BitBltMonitorToBitmapSource(EnumeratedMonitor monitor)
    {
        var desktopDC = NativeMethods.GetDC(IntPtr.Zero);
        if (desktopDC == IntPtr.Zero)
        {
            throw new InvalidOperationException("GetDC(desktop) returned NULL.");
        }

        IntPtr memoryDC = IntPtr.Zero;
        IntPtr compatibleBitmap = IntPtr.Zero;
        IntPtr previousBitmap = IntPtr.Zero;

        try
        {
            memoryDC = NativeMethods.CreateCompatibleDC(desktopDC);
            if (memoryDC == IntPtr.Zero)
            {
                throw new InvalidOperationException("CreateCompatibleDC failed.");
            }

            compatibleBitmap = NativeMethods.CreateCompatibleBitmap(
                desktopDC,
                monitor.PhysicalWidthPixels,
                monitor.PhysicalHeightPixels);
            if (compatibleBitmap == IntPtr.Zero)
            {
                throw new InvalidOperationException("CreateCompatibleBitmap failed.");
            }

            previousBitmap = NativeMethods.SelectObject(memoryDC, compatibleBitmap);

            var bitBltSucceeded = NativeMethods.BitBlt(
                hDCDest: memoryDC,
                xDest: 0, yDest: 0,
                width: monitor.PhysicalWidthPixels,
                height: monitor.PhysicalHeightPixels,
                hDCSource: desktopDC,
                xSource: monitor.BoundsLeft,
                ySource: monitor.BoundsTop,
                rop: NativeMethods.SRCCOPY | NativeMethods.CAPTUREBLT);

            if (!bitBltSucceeded)
            {
                var lastError = System.Runtime.InteropServices.Marshal.GetLastWin32Error();
                throw new InvalidOperationException($"BitBlt failed (Win32 error {lastError}).");
            }

            // Snapshot into a WPF BitmapSource. CreateBitmapSourceFromHBitmap
            // copies the pixels into managed memory — safe to free the
            // HBITMAP immediately after.
            var bitmapSource = Imaging.CreateBitmapSourceFromHBitmap(
                compatibleBitmap,
                IntPtr.Zero,
                Int32Rect.Empty,
                BitmapSizeOptions.FromEmptyOptions());
            bitmapSource.Freeze();
            return bitmapSource;
        }
        finally
        {
            if (previousBitmap != IntPtr.Zero && memoryDC != IntPtr.Zero)
            {
                NativeMethods.SelectObject(memoryDC, previousBitmap);
            }
            if (compatibleBitmap != IntPtr.Zero) NativeMethods.DeleteObject(compatibleBitmap);
            if (memoryDC != IntPtr.Zero) NativeMethods.DeleteDC(memoryDC);
            NativeMethods.ReleaseDC(IntPtr.Zero, desktopDC);
        }
    }

    private static BitmapSource DownscaleIfLarger(BitmapSource sourceBitmap, int maxLongestSide)
    {
        var longestSide = Math.Max(sourceBitmap.PixelWidth, sourceBitmap.PixelHeight);
        if (longestSide <= maxLongestSide) return sourceBitmap;

        var scaleFactor = (double)maxLongestSide / longestSide;
        var scaledTransform = new ScaleTransform(scaleFactor, scaleFactor);
        var transformedBitmap = new TransformedBitmap(sourceBitmap, scaledTransform);
        transformedBitmap.Freeze();
        return transformedBitmap;
    }

    private static byte[] EncodeAsJpeg(BitmapSource bitmap, int qualityPercent)
    {
        var encoder = new JpegBitmapEncoder { QualityLevel = qualityPercent };
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var memoryStream = new MemoryStream();
        encoder.Save(memoryStream);
        return memoryStream.ToArray();
    }

    /// <summary>
    /// Builds the per-monitor label the AI sees in the prompt. Matches the
    /// macOS format so prompt-engineering tweaks there translate directly.
    /// </summary>
    private static string BuildMonitorLabel(int orderedIndex, int totalCount, bool isCursorMonitor, bool isPrimaryMonitor)
    {
        var labelBuilder = new System.Text.StringBuilder();
        labelBuilder.Append("screen ").Append((orderedIndex + 1).ToString(CultureInfo.InvariantCulture));
        labelBuilder.Append(" of ").Append(totalCount.ToString(CultureInfo.InvariantCulture));

        if (isCursorMonitor)
        {
            labelBuilder.Append(" — cursor is on this screen (primary focus)");
        }
        else if (isPrimaryMonitor)
        {
            labelBuilder.Append(" — primary display");
        }
        return labelBuilder.ToString();
    }

    private sealed record EnumeratedMonitor(
        IntPtr Handle,
        int BoundsLeft,
        int BoundsTop,
        int PhysicalWidthPixels,
        int PhysicalHeightPixels,
        uint Flags,
        string DeviceName)
    {
        public bool HandleEquals(IntPtr otherHandle) => Handle == otherHandle && Handle != IntPtr.Zero;
    }
}

/// <summary>
/// A single captured monitor ready to ship to an AI provider. Mirrors the
/// macOS <c>CompanionScreenCapture</c> struct — field names adjusted for
/// C# conventions.
/// </summary>
public sealed record MonitorCapture(
    byte[] JpegData,
    string MimeType,
    string Label,
    bool IsCursorMonitor,
    int DisplayWidthPixels,
    int DisplayHeightPixels,
    int ScreenshotWidthPixels,
    int ScreenshotHeightPixels,
    Int32Rect DisplayBoundsDevicePixels);
