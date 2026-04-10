using System;
using System.Diagnostics;
using Microsoft.Win32;

namespace Clicky.App;

/// <summary>
/// Registers the app in HKCU\Software\Microsoft\Windows\CurrentVersion\Run
/// so it launches at user login. Mirrors SMAppService.mainApp.register() on macOS.
/// </summary>
public static class AutoStartRegistration
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string AppName = "Clicky";

    /// <summary>
    /// Registers the app for auto-start on first launch.
    /// If already registered, this is a no-op.
    /// </summary>
    public static void EnsureRegistered()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true);
            if (key is null) return;

            var existing = key.GetValue(AppName) as string;
            if (!string.IsNullOrEmpty(existing)) return;

            var exePath = Environment.ProcessPath;
            if (string.IsNullOrEmpty(exePath)) return;

            key.SetValue(AppName, $"\"{exePath}\"");
        }
        catch (Exception ex)
        {
            // Non-critical: log but don't block startup.
            Debug.WriteLine($"Failed to register auto-start: {ex.Message}");
        }
    }
}
