# AGENTS.md - leanring-buddy (Main App Target)

## Source Files

### ContextCircleManager.swift
- `ContextCircleManager` — `@MainActor` class managing the non-activating context circle and context editor `NSPanel` instances
  - `start()` — Begins visibility and cursor-screen placement updates
  - `stop()` — Stops placement updates and hides the circle and editor popup
  - circle click — Toggles the compact context editor popup without activating the app
  - file drop callback — Adds dragged files to `CompanionManager` context attachments
- `ContextCircleView` — Private SwiftUI circle view with hover/drop visual states and pointer cursor
- `ContextEditorView` — Private SwiftUI popup for Add file, Copy clipboard, remove attachment, and Clear actions
- `ContextCircleDropTargetView` — AppKit bridge for reliable file drops in the non-activating panel

### CompanionManager.swift
- Owns in-memory `ContextAttachment` values for text files, clipboard text, and clipboard images
- Validates supported text file extensions and attachment limits
- Adds attached text and images to the Claude request path for future voice turns

### leanring_buddyApp.swift
- Owns `ContextCircleManager` alongside `MenuBarPanelManager` and `CompanionManager`
- Starts and stops the context circle with the app lifecycle
