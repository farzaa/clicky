# AGENTS.md - leanring-buddy (Main App Target)

## Source Files

### FloatingSessionButton.swift
- `FloatingSessionButtonManager` — `@MainActor` class managing the `NSPanel` lifecycle
  - `showFloatingButton()` — Creates/shows the panel in top-right of primary screen
  - `hideFloatingButton()` — Hides panel (keeps it alive for quick re-show)
  - `destroyFloatingButton()` — Removes panel permanently (session ended)
  - `onFloatingButtonClicked` — Callback closure, set by ContentView to bring main window to front
  - `floatingButtonPanel` — Exposed `NSPanel` reference for screenshot exclusion
- `FloatingButtonView` — Private SwiftUI view with gradient circle, scale+glow hover animation, pointer cursor

### ContentView.swift
- Receives `FloatingSessionButtonManager` via `@EnvironmentObject`
- `isMainWindowCurrentlyFocused` — Tracks main window focus state
- `configureFloatingButtonManager()` — Wires up the click callback
- `startObservingMainWindowFocusChanges()` — Sets up `NSWindow` notification observers
- `updateFloatingButtonVisibility()` — Core logic: show if running + not focused, hide otherwise
- `bringMainWindowToFront()` — Activates app and orders main window front

### ScreenshotManager.swift
- `floatingButtonWindowToExcludeFromCaptures` — `NSWindow?` reference set by ContentView
- `captureScreen()` — Matches the floating window to an `SCWindow` and excludes it from capture filter

### leanring_buddyApp.swift
- Owns `FloatingSessionButtonManager` as `@StateObject`
- Injects it into ContentView via `.environmentObject()`
