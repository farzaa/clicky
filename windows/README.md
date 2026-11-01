# Clicky for Windows (community port, Groq powered)

A tray-resident Windows port of Clicky (the Mac app in `../leanring-buddy`) plus the agentic features of
HeyClicky: it sees your screen, talks to you, points at things, draws on your screen, shows 3D models,
and can drive the mouse and keyboard to do the task for you.

This is a community port built on the open-source Mac code. It is not the official HeyClicky app
(official downloads: https://www.heyclicky.com/for-windows).

Everything runs on **Groq** with **your own API key**. There is no Clicky server in between.

## Install and run

Requirements: Windows 10 or 11 (x64).

### Installer (recommended)

1. After enabling CI (below), open the GitHub Actions run "windows-build" and download the `Clicky-Setup-<version>.exe` artifact
   (or build it yourself, see below).
2. Run the installer. Clicky starts in the system tray and keeps running after you close any terminal.
3. Click the tray icon, paste your Groq key (get one at https://console.groq.com/keys), press Start.

### From source

```
cd windows
npm install
npm start
```

### Enable CI (one-time)

The workflow file is stored in `windows/ci/windows-build.yml` because the automated push could not write to
`.github/workflows/`. Enable it once with:

```
mkdir -p .github/workflows
cp windows/ci/windows-build.yml .github/workflows/windows-build.yml
git add .github && git commit -m "ci: enable windows build" && git push
```

Then each push builds the installer and uploads `Clicky-Setup-<version>.exe` as an artifact.

### Build the installer yourself

```
cd windows
npm install
npm run dist        # NSIS installer in windows/dist/
```

## Groq API key

Either:

- Paste it in the panel or in Home -> Settings. It is validated against Groq, then encrypted with
  Windows DPAPI (Electron `safeStorage`) and stored in your user profile.
- Or set the `GROQ_API_KEY` environment variable before launching. The environment variable wins over a stored key.

## Using it

| You do | What happens |
| --- | --- |
| Hold **Ctrl + Alt** (configurable) and talk | Push-to-talk. Release to send. Whisper transcribes, the model looks at a screenshot of every monitor, answers out loud, and the blue cursor flies to whatever it is explaining. |
| Ask "how do I ..." for something doable | Clicky offers to do it. A banner at the notch asks for approval, then it opens tabs, clicks buttons, types and presses keys itself. |
| Ask for a visual | It draws circles, arrows, boxes, underlines, highlights, paths, text and numbered steps over your screen, shows an info card with a photo, or opens an interactive 3D model. |
| Ask for something to run later | Routines (for example "every weekday at 09:00 open my dashboard") are managed in Home -> Routines. |
| Tell it to remember something | Facts are kept in Home -> Memory and used as context. You can delete them. |

Shortcut options: Control+Alt, Shift+Control, Control+Win, Control+Alt+Space, Shift+Control+Space.

### Home window

Chat, Agent jobs, Routines, Memory, Visuals and 3D, Settings. Open it from the tray menu.

### Safety when Clicky drives your computer

- Every driving task asks for approval first (buttons at the notch, or say yes / no). Switch to auto-approve only if you want to.
- **Esc** stops immediately. Moving the mouse by more than 14 px during a task also aborts it.
- PowerShell commands are approved one at a time and can be turned off completely.
- File tools only work inside your user folder.
- Screenshots are only taken when you press the hotkey or an approved task needs them.

## Privacy

- Audio and screenshots go straight from your PC to Groq over HTTPS, only when you trigger them.
- Nothing is sent to any Clicky/HeyClicky server. No analytics.
- Per Groq's current policy, API data is not used for training by default. Check their terms for your account.
- "Hide from screen capture" (default on) keeps Clicky's own windows out of screenshots and screen shares.
- Delete everything with Home -> Settings -> Reset.

## What Groq cannot do (limits and workarounds)

| Limit | Workaround in this port |
| --- | --- |
| No native "computer use" model that returns pixel clicks | Own grounding: screenshots with a 0-1000 normalised grid, plus an optional list of real UI elements from Windows UI Automation so the agent can click by name. Setting: Coordinate space / Accessibility grounding. |
| At most 3 images per request | Screens are ordered cursor screen first; extra monitors are dropped. |
| Orpheus TTS accepts about 200 characters per call and English voices only | Replies are split into sentence chunks and played back to back. Switch to the Windows (SAPI) voice engine for other languages. |
| Vision pointing is approximate on small or dense UI | Use the accessibility element list (on by default); the agent re-checks with a fresh screenshot after each action. |
| No browser extension / DOM access | The agent drives the browser like a user (keyboard, mouse, URLs, search, page fetch). Pages needing login or captchas need you. |
| Models can be wrong | Driving tasks are approved first and abortable at any moment. Do not leave payments or destructive tasks unattended. |
| 3D models are generated as JSON part lists (boxes, spheres, capsules...) | Good for diagrams of cells, engines, solar systems; not for photorealistic assets. |

## Verification status (please read)

This port was developed and tested in a Linux sandbox:

- 47 unit tests (`npm test`) cover tags, settings, prompts, key detection, screen maths, the companion state machine and the Win32/input layer against fakes.
- A headless end-to-end run (`npm run test:e2e`, Electron under Xvfb with a mock Groq server) checks the panel, overlay, pointing/drawing, Home window, notch prompts, 3D viewer and onboarding render and respond. It writes screenshots to `test/e2e/out/`.

It was **not** run on real Windows here. The parts that need a real Windows session are:
`user32` calls through koffi (`GetAsyncKeyState`, `SendInput`, `SetCursorPos`), transparent click-through overlays,
content protection, acrylic, the NSIS installer, DPAPI, and UI Automation via PowerShell. For these the repo ships:

- `scripts/win32-smoke.js`, run on `windows-latest` by the CI workflow in `ci/windows-build.yml` (see "Enable CI" below);
- the CI job also builds the installer and uploads it as an artifact.

Please do a manual pass on a real machine (hotkey, overlay on each monitor, a driving task, tray survive-close) and open an issue for anything that differs.

## Troubleshooting

- **Nothing happens on the hotkey**: another app may own the combination; pick a different one in Settings. AltGr is intentionally not treated as Ctrl+Alt.
- **Clicks land in the wrong place with display scaling**: keep Coordinate space on "normalized" (default).
- **No sound**: switch Voice engine to Windows in Settings, or press the test button next to the voice picker.
- **Microphone**: Windows Settings -> Privacy -> Microphone must allow desktop apps. The panel has a button that opens it.
- **Logs**: `%APPDATA%/Clicky/logs`.

## Layout

```
windows/
  src/main      Electron main process (tray, windows, Groq, agent, input, routines)
  src/renderer  panel, overlay, notch, home, model3d, audio host
  src/shared    motion constants shared with the Mac design tokens
  test/unit     node --test
  test/e2e      headless Electron scenario with mock Groq
  scripts       icons generator, Win32 smoke test
```
