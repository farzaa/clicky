# Clicky — Windows port

Native Windows port of the macOS Clicky app. Written in C# + WPF on .NET 8.

Shares the Cloudflare Worker proxy with the macOS app — `ANTHROPIC_API_KEY`,
`GEMINI_API_KEY`, `ASSEMBLYAI_API_KEY`, and `ELEVENLABS_API_KEY` all live on the
Worker, so the Windows app ships with zero embedded secrets.

## Milestone status

- [x] **M1 — Foundation**: tray icon, borderless popover panel, global push-to-talk hotkey infrastructure, settings persistence, design system parity with macOS.
- [x] **M2 — Voice pipeline**: NAudio microphone capture, AssemblyAI v3 streaming transcription, Claude + Gemini SSE chat, ElevenLabs TTS playback. Text-only; vision is added in M3 once screen capture lands.
- [x] **M3 — Screen capture**: per-monitor GDI `BitBlt` capture (PerMonitorV2-aware), JPEG encode at quality 80, downscale to 1280px longest side, cursor-monitor first. Screens feed into Claude/Gemini as inline images with labels like `"screen 1 of 2 — cursor is on this screen (primary focus) (image dimensions: 1280x800 pixels)"`. System prompt ported verbatim from macOS with the full pointing rules; the trailing `[POINT:…]` tag is stripped before TTS speaks the reply — M4/M5 will start consuming it.
- [x] **M4 — Cursor overlay**: one transparent, click-through, topmost `OverlayWindow` per connected display (WS_EX_TRANSPARENT + WS_EX_LAYERED + WS_EX_NOACTIVATE + WS_EX_TOOLWINDOW). A 16-DIP equilateral blue triangle (`#3380FF`, rotated -35°, blue glow) follows the system mouse at 60 fps via `DispatcherTimer` + `GetCursorPos`, offset 35 DIPs right / 25 DIPs down. Only the overlay on the cursor's monitor shows the triangle. Visible during `Idle` / `Responding`; hidden during `Listening` / `Processing` (those swap in waveform/spinner in M5/M6).
- [x] **M5 — Element pointing**: `PointingTagParser` splits each reply into spoken text + `(x, y, label, screenN)` target. `VoicePipelineOrchestrator` rescales screenshot pixels to the monitor's native device pixels and asks `OverlayWindowManager` to fly the triangle. `OverlayWindow.BeginElementPointingFlight` runs a quadratic bezier arc with smoothstep easing, tangent-based rotation (+90° so the tip leads travel), and a scale pulse peaking at 1.3× mid-flight — a port of macOS `animateBezierFlightArc`. On arrival the triangle lands 8/12 DIPs past the element, a blue speech bubble spring-bounces in with a random phrase ("right here!", "this one!", etc.) streamed 30-60 ms per character, holds 3 s, fades 500 ms, then the triangle flies back to the cursor. While any overlay is flying, the other overlays hide their cursor-follow triangles — single buddy at a time.
- [x] **M6 — Polish**: `MicrophonePermissionHelper` probes for an active capture endpoint at startup (a privacy-blocked mic moves to the `Disabled` state and is filtered out) and `AppState.IsMicrophonePermissionIssue` surfaces a "Open Windows privacy settings" callout in the tray panel that deep-links to `ms-settings:privacy-microphone`. First-run onboarding: if `HasCompletedOnboarding == false` the panel auto-opens centered on the primary monitor with a welcome block and a "Get started" button that flips the flag; a "Watch welcome again" footer link replays it. `ClickyAnalytics` POSTs directly to PostHog `/capture/` with the same event surface as the macOS `ClickyAnalytics.swift` (`app_opened`, `onboarding_*`, `permission_*`, `push_to_talk_*`, `user_message_sent`, `ai_response_received`, `element_pointed`, `response_error`, `tts_error`) using a stable anonymous per-install `distinct_id` persisted alongside settings. No opt-in toggle — matches macOS. The PostHog write key placeholder in `WorkerConfig.cs` must be swapped to enable telemetry; until then every event is silently dropped client-side.

## One-click install (recommended for non-developers)

If you just want to use Clicky and don't plan to touch the code, double-click
[windows/install/Install-Clicky.bat](install/Install-Clicky.bat). It runs
entirely per-user (no administrator rights) and will:

1. Verify the .NET 8 SDK is present (it's the only prerequisite — the
   installer asks you to install it from
   <https://dotnet.microsoft.com/download/dotnet/8.0> if missing).
2. Build Clicky as a self-contained single-file `Clicky.exe` so the target
   machine doesn't need the .NET runtime separately.
3. Copy it to `%LOCALAPPDATA%\Programs\Clicky\`.
4. Create **Start Menu** and **Desktop** shortcuts (`Clicky.lnk`), launched
   minimised since Clicky lives in the system tray.
5. Register Clicky in **Apps & Features** so you can uninstall it from
   Windows Settings like any other app.
6. Add Clicky to the per-user **Run** key so it launches automatically on
   login (pass `-NoAutoStart` to skip this, or `-NoLaunch` to finish without
   starting it immediately).
7. Launch Clicky — look for the blue dot in the system tray.

Advanced switches (run the `.ps1` directly from a PowerShell prompt):

```powershell
# Smaller framework-dependent build (requires .NET 8 Desktop Runtime on the target)
.\windows\install\Install-Clicky.ps1 -FrameworkDependent

# Don't register auto-start / don't launch after install
.\windows\install\Install-Clicky.ps1 -NoAutoStart -NoLaunch
```

> **Before first talk, edit the Worker URL.** Open
> [Clicky/Services/WorkerConfig.cs](Clicky/Services/WorkerConfig.cs) and
> replace the placeholder Cloudflare Worker base URL with your own. All API
> keys (Anthropic, Gemini, AssemblyAI, ElevenLabs) live on the Worker — the
> Windows app ships with zero embedded secrets. Re-run the installer after
> editing to rebuild. The same file also has a PostHog write key placeholder;
> swap it to enable analytics, or leave it and every event is silently
> dropped client-side.

To uninstall: open **Settings → Apps → Installed apps**, find **Clicky**, and
click Uninstall. Or run
`%LOCALAPPDATA%\Programs\Clicky\Uninstall-Clicky.ps1`.

## Requirements

- Windows 10 version 1903 (build 18362) or later — earlier builds lack APIs used by later milestones.
- [.NET 8 SDK](https://dotnet.microsoft.com/en-us/download/dotnet/8.0).
- Either Visual Studio 2022 (17.8+) with the ".NET desktop development" workload, **or** VS Code with the [C# Dev Kit extension](https://marketplace.visualstudio.com/items?itemName=ms-dotnettools.csdevkit) (only required if you plan to build/debug from source — the installer above handles builds for end-users).

## Build & run

```powershell
cd windows
dotnet restore
dotnet build
dotnet run --project Clicky
```

Or open `windows/Clicky.sln` in Visual Studio and press F5.

The app has no main window — it appears as a blue-dot icon in the system tray.
Click the icon to open the control panel. Hold **Ctrl + Alt** anywhere to talk;
release to send. The panel shows your transcript streaming in, then the
assistant's reply streaming out, then Clicky speaks it back via ElevenLabs.

> **Configure the Worker URL.** Before talking to Clicky, update
> [Services/WorkerConfig.cs](Clicky/Services/WorkerConfig.cs) with your own
> Cloudflare Worker base URL (the Swift app uses the same constant). All
> provider keys stay on the Worker — the Windows app ships with zero
> embedded secrets. The same file holds a placeholder PostHog write key —
> swap it for a real project key to enable analytics, or leave the
> placeholder in place and `ClickyAnalytics` silently drops every event.

## Project layout

```
windows/
  Clicky.sln
  install/
    Install-Clicky.bat             # double-click entry point (calls the .ps1 with ExecutionPolicy Bypass)
    Install-Clicky.ps1             # per-user installer: build + copy + shortcuts + Run key + Apps&Features entry
  Clicky/
    Clicky.csproj
    app.manifest               # PerMonitorV2 DPI awareness, asInvoker elevation
    App.xaml / App.xaml.cs     # entry point, tray + hotkey wiring, single-instance
    AppState.cs                # root observable state (equivalent of CompanionManager)
    Interop/
      NativeMethods.cs         # P/Invoke signatures — window styles, appbar, keyboard hook
    Resources/
      DesignSystem.xaml        # colors + radii ported 1:1 from macOS DesignSystem.swift
      clicky-tray.ico          # (optional — app falls back to a generated blue dot)
    Services/
      SettingsService.cs             # %APPDATA%\Clicky\settings.json persistence
      GlobalHotkeyService.cs         # low-level keyboard hook (Ctrl+Alt push-to-talk)
      WorkerConfig.cs                # Cloudflare Worker base URL + route constants
      IChatClient.cs                 # provider-agnostic streaming chat interface
      ClaudeClient.cs                # /chat SSE port of ClaudeAPI.swift
      GeminiClient.cs                # /chat-gemini SSE port of GeminiAPI.swift
      AssemblyAIStreamingClient.cs   # v3 realtime WebSocket transcription
      MicrophoneCaptureService.cs    # NAudio WaveInEvent, 16 kHz PCM16 mono
      ElevenLabsTtsClient.cs         # /tts MP3 fetch + NAudio playback
      DictationSession.cs            # mic -> AssemblyAI bridge + finalize-with-fallback
      ScreenCaptureService.cs        # per-monitor BitBlt -> JPEG (cursor monitor first)
      OverlayWindowManager.cs        # per-monitor overlay lifecycle + 60 fps cursor tracker + FlyToElement
      PointingTagParser.cs           # splits a reply into spoken text + [POINT:x,y:label:screenN] target
      MicrophonePermissionHelper.cs  # capture-endpoint probe + ms-settings:privacy-microphone shortcut
      ClickyAnalytics.cs             # PostHog /capture/ HTTP client, macOS event parity
      VoicePipelineOrchestrator.cs   # end-to-end push-to-talk -> capture -> AI -> TTS + pointing flow
    ViewModels/
      TrayPanelViewModel.cs    # model picker + quit command bindings
    Views/
      TrayPanelWindow.xaml     # borderless rounded popover UI
      TrayPanelWindow.xaml.cs  # non-activating window + positioning logic
      OverlayWindow.xaml       # transparent click-through per-monitor overlay
      OverlayWindow.xaml.cs    # blue triangle render + position updates
      StringToVisibilityConverter.cs # collapses empty-string bindings
```

## How this maps to the macOS app

| Windows | macOS equivalent |
|---------|------------------|
| `TaskbarIcon` (H.NotifyIcon.Wpf) | `NSStatusItem` in `MenuBarPanelManager.swift` |
| `TrayPanelWindow` | `CompanionPanelView` hosted in a borderless `NSPanel` |
| `GlobalHotkeyService` (WH_KEYBOARD_LL) | `GlobalPushToTalkShortcutMonitor.swift` (CGEvent tap) |
| `AppState` | `CompanionManager.swift` |
| `SettingsService` | `UserDefaults` in `CompanionManager` |
| `DesignSystem.xaml` | `DesignSystem.swift` |
| `ClaudeClient` / `GeminiClient` | `ClaudeAPI.swift` / `GeminiAPI.swift` |
| `AssemblyAIStreamingClient` | `AssemblyAIStreamingTranscriptionProvider.swift` |
| `MicrophoneCaptureService` (NAudio `WaveInEvent`) | `AVAudioEngine.inputNode.installTap` |
| `ElevenLabsTtsClient` (NAudio `Mp3FileReader` + `WaveOutEvent`) | `ElevenLabsTTSClient.swift` + `AVAudioPlayer` |
| `DictationSession` | `BuddyDictationManager.swift` |
| `ScreenCaptureService` (GDI BitBlt) | `CompanionScreenCaptureUtility.swift` (ScreenCaptureKit) |
| `OverlayWindow` + `OverlayWindowManager` | `OverlayWindow.swift` (`NSWindow` at `.screenSaver` level) |
| `VoicePipelineOrchestrator` | Transcript→capture→AI→TTS pipeline in `CompanionManager.swift` |
| Cloudflare Worker | Same Cloudflare Worker — unchanged |

## Tray icon

A real `clicky-tray.ico` (32×32, ICO format) dropped into `Clicky/Resources/`
and set to `Build Action = Resource` in the `.csproj` will be used at startup.
Without it, the app generates a solid blue dot in the overlay-cursor color
(`#3380FF`) as a placeholder so the tray is never empty.
