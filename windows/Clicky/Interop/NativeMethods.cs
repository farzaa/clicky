using System.Runtime.InteropServices;
using System.Windows;

namespace Clicky.Interop;

/// <summary>
/// Win32 P/Invoke surface. Grouped here so the rest of the app can stay
/// managed-code-only. Each method is documented with the underlying Win32
/// function it wraps.
/// </summary>
internal static class NativeMethods
{
    // ---- Extended window style bits used by the panel + overlay ----
    public const int GWL_EXSTYLE = -20;
    public const int WS_EX_TRANSPARENT = 0x00000020;
    public const int WS_EX_TOOLWINDOW = 0x00000080;
    public const int WS_EX_LAYERED = 0x00080000;
    public const int WS_EX_NOACTIVATE = 0x08000000;

    // ---- SetWindowPos flags (used for non-activating positioning) ----
    public static readonly IntPtr HWND_TOPMOST = new(-1);
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOACTIVATE = 0x0010;
    public const uint SWP_SHOWWINDOW = 0x0040;

    // ---- AppBar query for the Windows taskbar bounds ----
    public const uint ABM_GETTASKBARPOS = 0x00000005;

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetWindowPos(
        IntPtr hWnd,
        IntPtr hWndInsertAfter,
        int X,
        int Y,
        int cx,
        int cy,
        uint uFlags);

    // 32-bit and 64-bit variants of GetWindowLong / SetWindowLong. The correct
    // one is selected at runtime by GetExtendedStyle / SetExtendedStyle below.
    [DllImport("user32.dll", EntryPoint = "GetWindowLong")]
    private static extern int GetWindowLong32(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")]
    private static extern IntPtr GetWindowLongPtr64(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", EntryPoint = "SetWindowLong")]
    private static extern int SetWindowLong32(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")]
    private static extern IntPtr SetWindowLongPtr64(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

    public static int GetExtendedStyle(IntPtr hWnd)
    {
        return IntPtr.Size == 8
            ? (int)GetWindowLongPtr64(hWnd, GWL_EXSTYLE)
            : GetWindowLong32(hWnd, GWL_EXSTYLE);
    }

    public static void SetExtendedStyle(IntPtr hWnd, int newStyle)
    {
        if (IntPtr.Size == 8)
        {
            SetWindowLongPtr64(hWnd, GWL_EXSTYLE, new IntPtr(newStyle));
        }
        else
        {
            SetWindowLong32(hWnd, GWL_EXSTYLE, newStyle);
        }
    }

    // ---- Taskbar position (used to anchor the panel near the tray icon) ----

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;

        public int Width => Right - Left;
        public int Height => Bottom - Top;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct APPBARDATA
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uCallbackMessage;
        public uint uEdge;
        public RECT rc;
        public int lParam;
    }

    [DllImport("shell32.dll", CallingConvention = CallingConvention.StdCall)]
    public static extern IntPtr SHAppBarMessage(uint dwMessage, ref APPBARDATA pData);

    // ---- Low-level keyboard hook (push-to-talk hotkey detection) ----

    public const int WH_KEYBOARD_LL = 13;
    public const int WM_KEYDOWN = 0x0100;
    public const int WM_KEYUP = 0x0101;
    public const int WM_SYSKEYDOWN = 0x0104;
    public const int WM_SYSKEYUP = 0x0105;

    [StructLayout(LayoutKind.Sequential)]
    public struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public UIntPtr dwExtraInfo;
    }

    public delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    public static extern IntPtr GetModuleHandle(string? lpModuleName);

    // ---- Cursor position (used by the overlay cursor-follow logic) ----

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetCursorPos(out POINT lpPoint);

    // ---- DPI helpers (used when positioning the panel in device-pixel coords) ----

    /// <summary>
    /// Returns the device-to-DIP scale for the window's monitor. Multiply a
    /// device-pixel coord by the reciprocal to get WPF DIPs, or pass WPF DIPs
    /// in and multiply by this to get device pixels.
    /// </summary>
    public static double GetDpiScale(Window window)
    {
        var source = PresentationSource.FromVisual(window);
        return source?.CompositionTarget?.TransformToDevice.M11 ?? 1.0;
    }
}
