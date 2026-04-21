using System.ComponentModel;
using System.Windows.Threading;
using Clicky.Interop;
using Clicky.Views;

namespace Clicky.Services;

/// <summary>
/// Owns the per-monitor <see cref="OverlayWindow"/> instances and drives the
/// 60 fps cursor tracker that moves the blue triangle. Mirrors the macOS
/// <c>OverlayWindowManager</c> in <c>OverlayWindow.swift</c>.
///
/// Lifecycle:
///   1. <see cref="Start"/>   — enumerates monitors, spawns one overlay per
///      display, and starts the dispatcher timer.
///   2. Tracker tick — reads <c>GetCursorPos</c>, finds the monitor
///      containing the cursor, asks every overlay to re-render its
///      triangle (visible on the cursor's monitor, hidden elsewhere).
///   3. <see cref="Dispose"/> — stops the timer and closes every overlay.
///
/// Visibility follows <see cref="AppState.CurrentVoiceState"/> so the
/// triangle appears only during <c>Idle</c> / <c>Responding</c>, matching
/// the macOS contract (during <c>Listening</c> the waveform replaces it,
/// during <c>Processing</c> the spinner does — both are M5/M6 work; for
/// now the triangle simply hides and the system cursor stays).
/// </summary>
public sealed class OverlayWindowManager : IDisposable
{
    // 60 fps — matches the macOS Timer(withTimeInterval: 0.016). Feels
    // smooth and keeps CPU well below 1% of a modern core.
    private static readonly TimeSpan CursorTrackerInterval = TimeSpan.FromMilliseconds(16);

    private readonly AppState _appState;
    private readonly Dispatcher _uiDispatcher;
    private readonly List<MountedOverlay> _mountedOverlays = new();
    private DispatcherTimer? _cursorTrackerTimer;
    private bool _isDisposed;

    public OverlayWindowManager(AppState appState, Dispatcher uiDispatcher)
    {
        _appState = appState;
        _uiDispatcher = uiDispatcher;
    }

    /// <summary>
    /// Boots every overlay and starts the tracking timer. Must be called
    /// on the UI thread during app startup.
    /// </summary>
    public void Start()
    {
        foreach (var enumeratedMonitor in EnumerateMonitors())
        {
            var overlay = new OverlayWindow(
                monitorBoundsLeftDevicePixels: enumeratedMonitor.BoundsLeft,
                monitorBoundsTopDevicePixels: enumeratedMonitor.BoundsTop,
                monitorWidthDevicePixels: enumeratedMonitor.PhysicalWidthPixels,
                monitorHeightDevicePixels: enumeratedMonitor.PhysicalHeightPixels);
            overlay.ShowOnMonitor();
            _mountedOverlays.Add(new MountedOverlay(enumeratedMonitor, overlay));
        }

        _cursorTrackerTimer = new DispatcherTimer(DispatcherPriority.Render, _uiDispatcher)
        {
            Interval = CursorTrackerInterval,
        };
        _cursorTrackerTimer.Tick += OnCursorTrackerTick;
        _cursorTrackerTimer.Start();

        _appState.PropertyChanged += OnAppStatePropertyChanged;
    }

    private void OnCursorTrackerTick(object? sender, EventArgs eventArgs)
    {
        if (_mountedOverlays.Count == 0) return;
        if (!NativeMethods.GetCursorPos(out var cursorPositionDevicePixels)) return;

        var triangleShouldBeVisible = TriangleVisibleForVoiceState(_appState.CurrentVoiceState);

        foreach (var mountedOverlay in _mountedOverlays)
        {
            var cursorIsOnThisMonitor = mountedOverlay.Monitor.ContainsDevicePoint(
                cursorPositionDevicePixels.X,
                cursorPositionDevicePixels.Y);

            mountedOverlay.Window.UpdateCursorState(
                cursorGlobalDeviceX: cursorPositionDevicePixels.X,
                cursorGlobalDeviceY: cursorPositionDevicePixels.Y,
                cursorIsOnThisMonitor: cursorIsOnThisMonitor,
                triangleShouldBeVisible: triangleShouldBeVisible);
        }
    }

    /// <summary>
    /// Triangle is visible while the user is passively present (Idle) or
    /// hearing the response back (Responding). During Listening /
    /// Processing the macOS overlay swaps in a waveform / spinner — those
    /// are M5/M6 work; for now we just hide the triangle so the user
    /// sees the system cursor only.
    /// </summary>
    private static bool TriangleVisibleForVoiceState(AppState.VoiceState voiceState)
    {
        return voiceState == AppState.VoiceState.Idle
            || voiceState == AppState.VoiceState.Responding;
    }

    private void OnAppStatePropertyChanged(object? sender, PropertyChangedEventArgs args)
    {
        // Redraw on the next tick; no extra work required here — we only
        // subscribe so future state-based extras (e.g. waveform for
        // Listening in M5) have a hook to attach to.
    }

    // ---- Monitor enumeration ----
    // Duplicated from ScreenCaptureService rather than shared so each
    // feature owns a narrow, local view of the monitor topology. If a
    // third caller shows up we can extract a MonitorEnumerator.

    private static List<EnumeratedOverlayMonitor> EnumerateMonitors()
    {
        var enumeratedList = new List<EnumeratedOverlayMonitor>();

        bool MonitorEnumCallback(IntPtr hMonitor, IntPtr hdcMonitor, ref NativeMethods.RECT lprcMonitor, IntPtr dwData)
        {
            var monitorInfo = new NativeMethods.MONITORINFOEX
            {
                cbSize = System.Runtime.InteropServices.Marshal.SizeOf<NativeMethods.MONITORINFOEX>(),
            };
            if (!NativeMethods.GetMonitorInfo(hMonitor, ref monitorInfo))
            {
                return true;
            }

            enumeratedList.Add(new EnumeratedOverlayMonitor(
                Handle: hMonitor,
                BoundsLeft: monitorInfo.rcMonitor.Left,
                BoundsTop: monitorInfo.rcMonitor.Top,
                PhysicalWidthPixels: monitorInfo.rcMonitor.Width,
                PhysicalHeightPixels: monitorInfo.rcMonitor.Height));
            return true;
        }

        NativeMethods.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, MonitorEnumCallback, IntPtr.Zero);
        return enumeratedList;
    }

    public void Dispose()
    {
        if (_isDisposed) return;
        _isDisposed = true;

        _appState.PropertyChanged -= OnAppStatePropertyChanged;

        if (_cursorTrackerTimer is not null)
        {
            _cursorTrackerTimer.Stop();
            _cursorTrackerTimer.Tick -= OnCursorTrackerTick;
            _cursorTrackerTimer = null;
        }

        foreach (var mountedOverlay in _mountedOverlays)
        {
            try { mountedOverlay.Window.Close(); }
            catch { /* window already torn down during app shutdown — ignore */ }
        }
        _mountedOverlays.Clear();
    }

    private sealed record EnumeratedOverlayMonitor(
        IntPtr Handle,
        int BoundsLeft,
        int BoundsTop,
        int PhysicalWidthPixels,
        int PhysicalHeightPixels)
    {
        public bool ContainsDevicePoint(int globalDeviceX, int globalDeviceY)
        {
            return globalDeviceX >= BoundsLeft
                && globalDeviceX < BoundsLeft + PhysicalWidthPixels
                && globalDeviceY >= BoundsTop
                && globalDeviceY < BoundsTop + PhysicalHeightPixels;
        }
    }

    private sealed record MountedOverlay(EnumeratedOverlayMonitor Monitor, OverlayWindow Window);
}
