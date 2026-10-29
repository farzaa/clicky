using System.Diagnostics;
using NAudio.CoreAudioApi;

namespace Clicky.Services;

/// <summary>
/// Windows-only equivalent of the TCC microphone prompt in the macOS
/// <c>BuddyDictationManager.requestInitialPushToTalkPermissionsIfNeeded</c>.
///
/// There is no first-party Win32 API to prompt for microphone access on
/// unpackaged desktop apps — the privacy toggle lives in
/// <c>ms-settings:privacy-microphone</c>. The best we can do is:
///   1. probe for an active capture endpoint at startup so a disabled mic
///      is surfaced before the user tries to talk, and
///   2. offer a one-click shortcut to the relevant Settings page when a
///      capture attempt fails.
/// </summary>
public static class MicrophonePermissionHelper
{
    /// <summary>
    /// Returns <c>true</c> iff Windows has at least one <c>Active</c> capture
    /// endpoint — i.e. a microphone is present and the privacy/device toggle
    /// isn't blocking it. Privacy-blocked microphones move to the
    /// <c>Disabled</c> state and are excluded here.
    /// </summary>
    public static bool HasActiveCaptureDevice()
    {
        try
        {
            using var deviceEnumerator = new MMDeviceEnumerator();
            var activeCaptureEndpoints = deviceEnumerator.EnumerateAudioEndPoints(
                DataFlow.Capture,
                DeviceState.Active);
            return activeCaptureEndpoints.Count > 0;
        }
        catch
        {
            // MMDeviceEnumerator throwing usually means the audio service
            // is down or we're running in a very unusual environment — treat
            // as "no mic" so the UI nudges the user to check settings.
            return false;
        }
    }

    /// <summary>
    /// Opens the Windows 10/11 "Microphone" privacy page in Settings. Uses
    /// the <c>ms-settings:</c> protocol so the user lands one click away
    /// from the per-app toggle.
    /// </summary>
    public static void OpenWindowsMicrophonePrivacySettings()
    {
        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = "ms-settings:privacy-microphone",
                UseShellExecute = true,
            });
        }
        catch
        {
            // Settings URI handler missing — nothing useful to show the
            // user, they can open Settings manually.
        }
    }
}
