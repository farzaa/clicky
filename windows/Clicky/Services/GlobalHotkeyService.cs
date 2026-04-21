using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Input;
using Clicky.Interop;

namespace Clicky.Services;

/// <summary>
/// Detects the push-to-talk shortcut (Ctrl+Alt by default) system-wide via a
/// low-level keyboard hook. This is the Windows analog of the macOS CGEvent
/// tap used in GlobalPushToTalkShortcutMonitor.swift.
///
/// The hook is listen-only — we do NOT swallow the keys, so Ctrl+Alt combos
/// still reach other apps normally. Users can hold Ctrl+Alt to talk to Clicky
/// without breaking their current app's keyboard handling.
///
/// Events are raised on the thread that installed the hook (the UI thread).
/// Subscribers should keep handlers short to avoid stalling global keyboard
/// delivery — dispatch heavy work off-thread immediately.
/// </summary>
public sealed class GlobalHotkeyService : IDisposable
{
    private IntPtr _hookHandle = IntPtr.Zero;

    // Held as a field so the GC doesn't collect the delegate while the hook
    // is installed — that would cause a nasty access violation in user32.dll.
    private NativeMethods.LowLevelKeyboardProc? _hookCallback;

    private bool _isCtrlHeld;
    private bool _isAltHeld;
    private bool _isShortcutActive;

    /// <summary>
    /// Raised when the push-to-talk combination transitions to held.
    /// Subscribers should begin recording immediately.
    /// </summary>
    public event EventHandler? ShortcutPressed;

    /// <summary>
    /// Raised when either modifier in the push-to-talk combination is released.
    /// Subscribers should finalize the recording and submit the transcript.
    /// </summary>
    public event EventHandler? ShortcutReleased;

    public void Start()
    {
        if (_hookHandle != IntPtr.Zero)
        {
            return;
        }

        _hookCallback = HookCallback;
        using var process = Process.GetCurrentProcess();
        using var module = process.MainModule
            ?? throw new InvalidOperationException("Cannot read main module for hook installation.");
        var moduleHandle = NativeMethods.GetModuleHandle(module.ModuleName);

        _hookHandle = NativeMethods.SetWindowsHookEx(
            NativeMethods.WH_KEYBOARD_LL,
            _hookCallback,
            moduleHandle,
            0);

        if (_hookHandle == IntPtr.Zero)
        {
            throw new InvalidOperationException(
                $"Failed to install low-level keyboard hook (GetLastError={Marshal.GetLastWin32Error()}).");
        }
    }

    public void Stop()
    {
        if (_hookHandle == IntPtr.Zero)
        {
            return;
        }

        NativeMethods.UnhookWindowsHookEx(_hookHandle);
        _hookHandle = IntPtr.Zero;
        _hookCallback = null;
        _isCtrlHeld = false;
        _isAltHeld = false;
        _isShortcutActive = false;
    }

    public void Dispose() => Stop();

    private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode < 0)
        {
            return NativeMethods.CallNextHookEx(_hookHandle, nCode, wParam, lParam);
        }

        var hookStruct = Marshal.PtrToStructure<NativeMethods.KBDLLHOOKSTRUCT>(lParam);
        var virtualKey = (Key)KeyInterop.KeyFromVirtualKey((int)hookStruct.vkCode);
        var messageCode = wParam.ToInt32();

        var isKeyDown = messageCode == NativeMethods.WM_KEYDOWN || messageCode == NativeMethods.WM_SYSKEYDOWN;
        var isKeyUp = messageCode == NativeMethods.WM_KEYUP || messageCode == NativeMethods.WM_SYSKEYUP;

        // Track only Ctrl and Alt — left and right variants both map to the
        // same push-to-talk action (matches macOS left/right option behavior).
        var isCtrlKey = virtualKey is Key.LeftCtrl or Key.RightCtrl;
        var isAltKey = virtualKey is Key.LeftAlt or Key.RightAlt;

        if (isCtrlKey)
        {
            if (isKeyDown) _isCtrlHeld = true;
            else if (isKeyUp) _isCtrlHeld = false;
        }
        else if (isAltKey)
        {
            if (isKeyDown) _isAltHeld = true;
            else if (isKeyUp) _isAltHeld = false;
        }
        else
        {
            // Any non-modifier keystroke cancels the shortcut. Without this,
            // "Ctrl+Alt+T" (or any typing combo) would fire push-to-talk.
            if (_isShortcutActive)
            {
                _isShortcutActive = false;
                ShortcutReleased?.Invoke(this, EventArgs.Empty);
            }

            return NativeMethods.CallNextHookEx(_hookHandle, nCode, wParam, lParam);
        }

        var shouldBeActive = _isCtrlHeld && _isAltHeld;

        if (shouldBeActive && !_isShortcutActive)
        {
            _isShortcutActive = true;
            ShortcutPressed?.Invoke(this, EventArgs.Empty);
        }
        else if (!shouldBeActive && _isShortcutActive)
        {
            _isShortcutActive = false;
            ShortcutReleased?.Invoke(this, EventArgs.Empty);
        }

        return NativeMethods.CallNextHookEx(_hookHandle, nCode, wParam, lParam);
    }
}
