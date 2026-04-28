using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Threading;
using Clicky.Interop;

namespace Clicky.Views;

/// <summary>
/// Transparent, click-through, always-on-top overlay covering a single
/// monitor. Renders the blue triangle cursor that follows the system mouse
/// and, during element pointing (M5), animates along a bezier arc to a
/// target location and shows a speech bubble.
///
/// One instance is created per connected display; the
/// <see cref="Services.OverlayWindowManager"/> owns their lifecycle, the
/// cursor-tracking timer, and the per-element flight requests.
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

    // Element-target offset: the triangle lands *next to* the element,
    // not on top of it — 8 DIPs right and 12 DIPs below, matching
    // macOS OverlayWindow.startNavigatingToElement.
    private const double ElementOffsetDipX = 8;
    private const double ElementOffsetDipY = 12;

    // Speech bubble sits to the lower-right of the triangle tip (same
    // relative position as macOS: x + 10, y + 18 in DIPs).
    private const double BubbleOffsetDipX = 10;
    private const double BubbleOffsetDipY = 18;

    // Triangle bounding box (16 × 13.856 DIPs). RenderTransformOrigin is
    // (0.5, 1/3) so the rotation/scale pivot is the centroid. When we move
    // the triangle we place that centroid at the target position — these
    // constants shift Canvas.Left/Top from centroid-coord back to bounding-
    // box coord.
    private const double TriangleBoundingBoxDipWidth = 16.0;
    private const double TriangleBoundingBoxDipHeight = 13.856;
    private const double TriangleCentroidOffsetDipX = TriangleBoundingBoxDipWidth / 2.0;
    private const double TriangleCentroidOffsetDipY = TriangleBoundingBoxDipHeight / 3.0;

    // Default "resting" rotation for the triangle (matches the macOS -35°).
    private const double RestingRotationDegrees = -35.0;

    private const int AnimationFramesPerSecond = 60;
    private static readonly TimeSpan AnimationFrameInterval =
        TimeSpan.FromSeconds(1.0 / AnimationFramesPerSecond);

    // Bezier flight clamps — duration scales linearly with distance / 800 DIPs,
    // clamped to [0.6s, 1.4s] so tiny hops still feel purposeful and cross-
    // monitor flights don't drag on forever.
    private const double FlightMinDurationSeconds = 0.6;
    private const double FlightMaxDurationSeconds = 1.4;
    private const double FlightDurationDistanceDivisor = 800.0;

    // Bubble hold before flying back, matches macOS (3s pill + 0.5s fade).
    private static readonly TimeSpan BubbleHoldDuration = TimeSpan.FromSeconds(3.0);
    private static readonly TimeSpan BubbleFadeDuration = TimeSpan.FromMilliseconds(500);

    private readonly int _monitorBoundsLeftDevicePixels;
    private readonly int _monitorBoundsTopDevicePixels;
    private readonly int _monitorWidthDevicePixels;
    private readonly int _monitorHeightDevicePixels;

    private bool _hasBeenPositioned;

    // Flight state. When _isFlightActive is true, the cursor-follow path
    // in UpdateCursorState is skipped — the flight animation drives the
    // triangle position directly.
    private bool _isFlightActive;
    private DispatcherTimer? _flightFrameTimer;

    // Position in DIPs where the triangle currently sits (as last rendered).
    // Flights start from this point so successive calls chain smoothly.
    private double _triangleCurrentDipX;
    private double _triangleCurrentDipY;

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

    /// <summary>True while a flight/point/return sequence is running on
    /// this overlay. The manager consults this to suppress cursor updates
    /// here and on other overlays.</summary>
    public bool IsFlightInProgress => _isFlightActive;

    /// <summary>
    /// Updates the overlay's triangle for a single cursor tracker tick.
    /// Ignored while a flight is active — the flight animation owns the
    /// triangle's position and rotation for its duration.
    /// </summary>
    public void UpdateCursorState(
        int cursorGlobalDeviceX,
        int cursorGlobalDeviceY,
        bool cursorIsOnThisMonitor,
        bool triangleShouldBeVisible)
    {
        if (!_hasBeenPositioned) return;
        if (_isFlightActive) return;

        if (!cursorIsOnThisMonitor || !triangleShouldBeVisible)
        {
            if (BlueTriangle.Visibility != Visibility.Collapsed)
            {
                BlueTriangle.Visibility = Visibility.Collapsed;
            }
            return;
        }

        var (localDipX, localDipY) = ConvertGlobalDeviceToLocalDip(cursorGlobalDeviceX, cursorGlobalDeviceY);
        var triangleDipX = localDipX + CursorOffsetDipX;
        var triangleDipY = localDipY + CursorOffsetDipY;
        PositionTriangle(triangleDipX, triangleDipY);

        // Keep the resting pose while cursor-following.
        BlueTriangleRotation.Angle = RestingRotationDegrees;
        BlueTriangleScale.ScaleX = 1.0;
        BlueTriangleScale.ScaleY = 1.0;

        if (BlueTriangle.Visibility != Visibility.Visible)
        {
            BlueTriangle.Visibility = Visibility.Visible;
        }
    }

    /// <summary>
    /// Starts the full element-pointing sequence on this overlay:
    /// bezier flight out → speech bubble hold → bezier flight back to the
    /// current cursor. All UI updates happen on the caller's Dispatcher
    /// (expected to be the UI thread).
    /// </summary>
    /// <param name="targetDisplayLocalDeviceX">Target X in device pixels, local to this monitor's top-left.</param>
    /// <param name="targetDisplayLocalDeviceY">Target Y in device pixels, local to this monitor's top-left.</param>
    /// <param name="bubblePhrase">Text for the speech bubble. Streamed character-by-character with jittered delays.</param>
    public void BeginElementPointingFlight(
        double targetDisplayLocalDeviceX,
        double targetDisplayLocalDeviceY,
        string bubblePhrase)
    {
        if (!_hasBeenPositioned) return;

        var dpiScale = NativeMethods.GetDpiScale(this);
        if (dpiScale <= 0) dpiScale = 1.0;

        var targetDipX = targetDisplayLocalDeviceX / dpiScale;
        var targetDipY = targetDisplayLocalDeviceY / dpiScale;

        // Offset so the triangle lands beside the element. Clamp inside the
        // overlay bounds with a small margin so the triangle never clips off
        // the edge of the monitor.
        var monitorWidthDip = _monitorWidthDevicePixels / dpiScale;
        var monitorHeightDip = _monitorHeightDevicePixels / dpiScale;
        var destinationDipX = Math.Clamp(targetDipX + ElementOffsetDipX, 20, Math.Max(20, monitorWidthDip - 20));
        var destinationDipY = Math.Clamp(targetDipY + ElementOffsetDipY, 20, Math.Max(20, monitorHeightDip - 20));

        // Starting point = current triangle position (if we don't have one,
        // fall back to the system cursor's local position so the first
        // flight of the app still looks natural).
        EnsureCurrentTrianglePositionInitialized();

        _isFlightActive = true;
        BlueTriangle.Visibility = Visibility.Visible;

        FlyTriangleAlongBezier(
            startDipX: _triangleCurrentDipX,
            startDipY: _triangleCurrentDipY,
            endDipX: destinationDipX,
            endDipY: destinationDipY,
            onFlightComplete: () => ShowPointerBubbleAndScheduleReturn(bubblePhrase));
    }

    private void ShowPointerBubbleAndScheduleReturn(string bubblePhrase)
    {
        // Triangle has arrived — reset rotation and scale, then bounce the
        // bubble in with streaming text.
        BlueTriangleRotation.Angle = RestingRotationDegrees;
        BlueTriangleScale.ScaleX = 1.0;
        BlueTriangleScale.ScaleY = 1.0;

        PositionPointerBubble();
        PointerBubbleText.Text = string.Empty;
        PointerBubble.Opacity = 1.0;
        PointerBubbleScale.ScaleX = 0.5;
        PointerBubbleScale.ScaleY = 0.5;
        PointerBubble.Visibility = Visibility.Visible;

        // Spring-bounce the bubble to 1.0x — WPF has no spring easing, so a
        // short ease-out gives a close-enough bounce for this size.
        AnimateBubbleScaleTo(targetScale: 1.0, durationMs: 260);

        StreamBubbleCharacters(bubblePhrase, characterIndex: 0, onStreamComplete: () =>
        {
            // Hold for 3s, fade out 0.5s, then fly back.
            var holdTimer = new DispatcherTimer { Interval = BubbleHoldDuration };
            holdTimer.Tick += (_, _) =>
            {
                holdTimer.Stop();
                FadeOutBubbleThenFlyBack();
            };
            holdTimer.Start();
        });
    }

    private void FadeOutBubbleThenFlyBack()
    {
        var fadeTimer = new DispatcherTimer { Interval = AnimationFrameInterval };
        var fadeStartTime = DateTime.UtcNow;

        fadeTimer.Tick += (_, _) =>
        {
            var elapsed = DateTime.UtcNow - fadeStartTime;
            var progress = Math.Clamp(elapsed.TotalMilliseconds / BubbleFadeDuration.TotalMilliseconds, 0.0, 1.0);
            PointerBubble.Opacity = 1.0 - progress;

            if (progress >= 1.0)
            {
                fadeTimer.Stop();
                PointerBubble.Visibility = Visibility.Collapsed;
                PointerBubbleText.Text = string.Empty;
                FlyTriangleBackToCursor();
            }
        };
        fadeTimer.Start();
    }

    private void FlyTriangleBackToCursor()
    {
        // Return target = system cursor + follow-offset, in local DIPs.
        if (!NativeMethods.GetCursorPos(out var cursorDevicePixels))
        {
            EndFlight();
            return;
        }

        var (cursorLocalDipX, cursorLocalDipY) = ConvertGlobalDeviceToLocalDip(cursorDevicePixels.X, cursorDevicePixels.Y);
        var returnDipX = cursorLocalDipX + CursorOffsetDipX;
        var returnDipY = cursorLocalDipY + CursorOffsetDipY;

        FlyTriangleAlongBezier(
            startDipX: _triangleCurrentDipX,
            startDipY: _triangleCurrentDipY,
            endDipX: returnDipX,
            endDipY: returnDipY,
            onFlightComplete: EndFlight);
    }

    private void EndFlight()
    {
        _isFlightActive = false;
        BlueTriangleRotation.Angle = RestingRotationDegrees;
        BlueTriangleScale.ScaleX = 1.0;
        BlueTriangleScale.ScaleY = 1.0;
    }

    /// <summary>
    /// Bezier flight with smoothstep easing, tangent-based rotation and a
    /// scale pulse peaking at the midpoint — straight port of the macOS
    /// animateBezierFlightArc.
    /// </summary>
    private void FlyTriangleAlongBezier(
        double startDipX,
        double startDipY,
        double endDipX,
        double endDipY,
        Action onFlightComplete)
    {
        _flightFrameTimer?.Stop();

        var deltaX = endDipX - startDipX;
        var deltaY = endDipY - startDipY;
        var distance = Math.Sqrt(deltaX * deltaX + deltaY * deltaY);

        var flightDurationSeconds = Math.Clamp(
            distance / FlightDurationDistanceDivisor,
            FlightMinDurationSeconds,
            FlightMaxDurationSeconds);
        var totalFrames = Math.Max(1, (int)(flightDurationSeconds * AnimationFramesPerSecond));

        // Arc control point — lifted upward (negative Y in screen coords)
        // so the triangle swoops. Height capped at 80 DIPs like macOS.
        var midpointDipX = (startDipX + endDipX) / 2.0;
        var midpointDipY = (startDipY + endDipY) / 2.0;
        var arcHeight = Math.Min(distance * 0.2, 80.0);
        var controlPointDipX = midpointDipX;
        var controlPointDipY = midpointDipY - arcHeight;

        var currentFrame = 0;
        _flightFrameTimer = new DispatcherTimer(DispatcherPriority.Render, Dispatcher)
        {
            Interval = AnimationFrameInterval,
        };
        _flightFrameTimer.Tick += (_, _) =>
        {
            currentFrame++;

            if (currentFrame > totalFrames)
            {
                _flightFrameTimer.Stop();
                _flightFrameTimer = null;
                PositionTriangle(endDipX, endDipY);
                BlueTriangleScale.ScaleX = 1.0;
                BlueTriangleScale.ScaleY = 1.0;
                _triangleCurrentDipX = endDipX;
                _triangleCurrentDipY = endDipY;
                onFlightComplete();
                return;
            }

            var linearProgress = (double)currentFrame / totalFrames;
            // Smoothstep easeInOut: 3t² - 2t³
            var t = linearProgress * linearProgress * (3.0 - 2.0 * linearProgress);
            var oneMinusT = 1.0 - t;

            // Quadratic bezier B(t)
            var bezierDipX = oneMinusT * oneMinusT * startDipX
                           + 2.0 * oneMinusT * t * controlPointDipX
                           + t * t * endDipX;
            var bezierDipY = oneMinusT * oneMinusT * startDipY
                           + 2.0 * oneMinusT * t * controlPointDipY
                           + t * t * endDipY;
            PositionTriangle(bezierDipX, bezierDipY);

            // Rotation along the curve tangent B'(t). The +90° offset aligns
            // the triangle's tip (which points up at 0°) with the direction
            // of travel returned by atan2.
            var tangentX = 2.0 * oneMinusT * (controlPointDipX - startDipX)
                         + 2.0 * t * (endDipX - controlPointDipX);
            var tangentY = 2.0 * oneMinusT * (controlPointDipY - startDipY)
                         + 2.0 * t * (endDipY - controlPointDipY);
            BlueTriangleRotation.Angle = Math.Atan2(tangentY, tangentX) * (180.0 / Math.PI) + 90.0;

            // Scale pulse — sin curve, peaks at 1.3× at mid-flight.
            var scalePulse = 1.0 + Math.Sin(linearProgress * Math.PI) * 0.3;
            BlueTriangleScale.ScaleX = scalePulse;
            BlueTriangleScale.ScaleY = scalePulse;
        };
        _flightFrameTimer.Start();
    }

    private void StreamBubbleCharacters(string phrase, int characterIndex, Action onStreamComplete)
    {
        if (!_isFlightActive)
        {
            // Flight was cancelled / interrupted — stop streaming.
            return;
        }

        if (characterIndex >= phrase.Length)
        {
            onStreamComplete();
            return;
        }

        PointerBubbleText.Text += phrase[characterIndex];
        PositionPointerBubble();

        var characterDelayMs = 30 + Random.Shared.Next(31); // 30..60 ms
        var characterTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(characterDelayMs) };
        characterTimer.Tick += (_, _) =>
        {
            characterTimer.Stop();
            StreamBubbleCharacters(phrase, characterIndex + 1, onStreamComplete);
        };
        characterTimer.Start();
    }

    private void AnimateBubbleScaleTo(double targetScale, int durationMs)
    {
        var startingScale = PointerBubbleScale.ScaleX;
        var startTime = DateTime.UtcNow;
        var scaleTimer = new DispatcherTimer(DispatcherPriority.Render, Dispatcher)
        {
            Interval = AnimationFrameInterval,
        };
        scaleTimer.Tick += (_, _) =>
        {
            var elapsed = (DateTime.UtcNow - startTime).TotalMilliseconds;
            var progress = Math.Clamp(elapsed / durationMs, 0.0, 1.0);
            // Ease-out cubic for a gentle overshoot-free bounce.
            var eased = 1.0 - Math.Pow(1.0 - progress, 3.0);
            var currentScale = startingScale + (targetScale - startingScale) * eased;
            PointerBubbleScale.ScaleX = currentScale;
            PointerBubbleScale.ScaleY = currentScale;

            if (progress >= 1.0)
            {
                scaleTimer.Stop();
            }
        };
        scaleTimer.Start();
    }

    private void EnsureCurrentTrianglePositionInitialized()
    {
        if (_triangleCurrentDipX != 0 || _triangleCurrentDipY != 0) return;

        // No prior position recorded — seed from the current system cursor.
        if (!NativeMethods.GetCursorPos(out var cursorDevicePixels)) return;
        var (cursorLocalDipX, cursorLocalDipY) = ConvertGlobalDeviceToLocalDip(cursorDevicePixels.X, cursorDevicePixels.Y);
        _triangleCurrentDipX = cursorLocalDipX + CursorOffsetDipX;
        _triangleCurrentDipY = cursorLocalDipY + CursorOffsetDipY;
        PositionTriangle(_triangleCurrentDipX, _triangleCurrentDipY);
    }

    private void PositionTriangle(double centroidDipX, double centroidDipY)
    {
        Canvas.SetLeft(BlueTriangle, centroidDipX - TriangleCentroidOffsetDipX);
        Canvas.SetTop(BlueTriangle, centroidDipY - TriangleCentroidOffsetDipY);
        _triangleCurrentDipX = centroidDipX;
        _triangleCurrentDipY = centroidDipY;
        if (PointerBubble.Visibility == Visibility.Visible)
        {
            PositionPointerBubble();
        }
    }

    private void PositionPointerBubble()
    {
        // Measure the bubble so we can center it around (triangle + offset).
        PointerBubble.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var bubbleDesired = PointerBubble.DesiredSize;

        var anchorDipX = _triangleCurrentDipX + BubbleOffsetDipX;
        var anchorDipY = _triangleCurrentDipY + BubbleOffsetDipY;
        Canvas.SetLeft(PointerBubble, anchorDipX - bubbleDesired.Width / 2.0);
        Canvas.SetTop(PointerBubble, anchorDipY - bubbleDesired.Height / 2.0);
    }

    private (double LocalDipX, double LocalDipY) ConvertGlobalDeviceToLocalDip(int globalDeviceX, int globalDeviceY)
    {
        var dpiScale = NativeMethods.GetDpiScale(this);
        if (dpiScale <= 0) dpiScale = 1.0;

        var localDeviceX = globalDeviceX - _monitorBoundsLeftDevicePixels;
        var localDeviceY = globalDeviceY - _monitorBoundsTopDevicePixels;
        return (localDeviceX / dpiScale, localDeviceY / dpiScale);
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
