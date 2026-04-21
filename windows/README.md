# Clicky — Windows port

Native Windows port of the macOS Clicky app. Written in C# + WPF on .NET 8.

Shares the Cloudflare Worker proxy with the macOS app — `ANTHROPIC_API_KEY`,
`GEMINI_API_KEY`, `ASSEMBLYAI_API_KEY`, and `ELEVENLABS_API_KEY` all live on the
Worker, so the Windows app ships with zero embedded secrets.

## Milestone status

- [x] **M1 — Foundation**: tray icon, borderless popover panel, global push-to-talk hotkey infrastructure, settings persistence, design system parity with macOS.
- [ ] **M2 — Voice pipeline**: microphone capture, AssemblyAI streaming transcription, Claude / Gemini vision calls, ElevenLabs TTS playback.
- [ ] **M3 — Screen capture**: per-monitor `Windows.Graphics.Capture` with DPI-correct coordinate mapping.
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
Click the icon to open the control panel. Hold **Ctrl + Alt** anywhere to talk
(voice pipeline arrives in M2).

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
      SettingsService.cs       # %APPDATA%\Clicky\settings.json persistence
      GlobalHotkeyService.cs   # low-level keyboard hook (Ctrl+Alt push-to-talk)
    ViewModels/
      TrayPanelViewModel.cs    # model picker + quit command bindings
    Views/
      TrayPanelWindow.xaml     # borderless rounded popover UI
      TrayPanelWindow.xaml.cs  # non-activating window + positioning logic
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
| Cloudflare Worker | Same Cloudflare Worker — unchanged |

## Tray icon

A real `clicky-tray.ico` (32×32, ICO format) dropped into `Clicky/Resources/`
and set to `Build Action = Resource` in the `.csproj` will be used at startup.
Without it, the app generates a solid blue dot in the overlay-cursor color
(`#3380FF`) as a placeholder so the tray is never empty.
