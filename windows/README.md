# Clicky — Windows port

Native Windows port of the macOS Clicky app. Written in C# + WPF on .NET 8.

Shares the Cloudflare Worker proxy with the macOS app — `ANTHROPIC_API_KEY`,
`GEMINI_API_KEY`, `ASSEMBLYAI_API_KEY`, and `ELEVENLABS_API_KEY` all live on the
Worker, so the Windows app ships with zero embedded secrets.

## Milestone status

- [x] **M1 — Foundation**: tray icon, borderless popover panel, global push-to-talk hotkey infrastructure, settings persistence, design system parity with macOS.
- [x] **M2 — Voice pipeline**: NAudio microphone capture, AssemblyAI v3 streaming transcription, Claude + Gemini SSE chat, ElevenLabs TTS playback. Text-only; vision is added in M3 once screen capture lands.
- [ ] **M3 — Screen capture**: per-monitor `Windows.Graphics.Capture` with DPI-correct coordinate mapping. Feeds captured JPEGs as inline images into the M2 chat clients.
- [ ] **M4 — Cursor overlay**: transparent per-monitor overlay windows, blue triangle cursor following the system mouse.
- [ ] **M5 — Element pointing**: `[POINT:x,y:label:screenN]` parser, bezier flight animation, speech bubble.
- [ ] **M6 — Polish**: permission checks, onboarding flow, analytics parity.

## Requirements

- Windows 10 version 1903 (build 18362) or later — earlier builds lack APIs used by later milestones.
- [.NET 8 SDK](https://dotnet.microsoft.com/en-us/download/dotnet/8.0).
- Either Visual Studio 2022 (17.8+) with the ".NET desktop development" workload, **or** VS Code with the [C# Dev Kit extension](https://marketplace.visualstudio.com/items?itemName=ms-dotnettools.csdevkit).

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
> embedded secrets.

## Project layout

```
windows/
  Clicky.sln
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
      VoicePipelineOrchestrator.cs   # end-to-end push-to-talk -> AI -> TTS flow
    ViewModels/
      TrayPanelViewModel.cs    # model picker + quit command bindings
    Views/
      TrayPanelWindow.xaml     # borderless rounded popover UI
      TrayPanelWindow.xaml.cs  # non-activating window + positioning logic
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
| `VoicePipelineOrchestrator` | Transcript→AI→TTS pipeline in `CompanionManager.swift` |
| Cloudflare Worker | Same Cloudflare Worker — unchanged |

## Tray icon

A real `clicky-tray.ico` (32×32, ICO format) dropped into `Clicky/Resources/`
and set to `Build Action = Resource` in the `.csproj` will be used at startup.
Without it, the app generates a solid blue dot in the overlay-cursor color
(`#3380FF`) as a placeholder so the tray is never empty.
