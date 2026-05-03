//
//  ChatInputBubbleManager.swift
//  leanring-buddy
//
//  Owns the floating chat input bubble's `NSPanel` lifecycle. The panel is
//  borderless, transparent, and non-activating so it doesn't steal focus
//  from the user's current app — it merely accepts key input while visible.
//
//  Mirrors the panel style used by `MenuBarPanelManager`: a `KeyablePanel`
//  subclass overrides `canBecomeKey` so the embedded SwiftUI text field can
//  receive focus, and a global click-outside monitor dismisses the panel
//  when the user clicks anywhere else.
//
//  Position: the bubble is anchored to the AI cursor, which itself sits at
//  `mouseLocation + (35, -25)` in AppKit screen coords (matching the offset
//  used in `OverlayWindow.BlueCursorView`). The bubble's tail points at the
//  cursor, and a 60fps timer re-positions the panel as the user moves their
//  mouse so the bubble follows the cursor in real time.
//

import AppKit
import SwiftUI

/// `NSPanel` subclass whose `canBecomeKey` returns true so the SwiftUI
/// `TextField` inside the chat bubble can become first responder despite
/// the panel being a non-activating floating panel. This is the same
/// trick used by `MenuBarPanelManager.KeyablePanel`.
private final class ChatInputBubblePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class ChatInputBubbleManager: NSObject {
    private var panel: ChatInputBubblePanel?
    private var clickOutsideMonitor: Any?
    /// Local key-event monitor that catches the Escape key while the
    /// bubble is the key window. SwiftUI's `.keyboardShortcut(.cancelAction)`
    /// is unreliable inside non-activating NSPanels, so we intercept the
    /// raw key event here.
    private var escapeKeyMonitor: Any?
    /// Timer that re-positions the panel as the mouse moves, so the bubble
    /// follows the cursor like the AI cursor itself does.
    private var mouseTrackingTimer: Timer?

    /// Bubble dimensions — sized to fit the bubble's natural padded
    /// content exactly, with no extra buffer around it. The bubble is
    /// flat (no drop shadow) so it doesn't need extra panel margin to
    /// avoid clipping at the panel edges.
    private let panelWidth: CGFloat = 280
    private let panelHeight: CGFloat = 44

    /// Horizontal offset from the mouse to the AI cursor's center, mirroring
    /// `OverlayWindow.BlueCursorView`'s `swiftUIPosition.x + 35`.
    private let cursorOffsetXFromMouse: CGFloat = 35
    /// Vertical offset from the mouse to the AI cursor's center. The mouse-
    /// to-cursor offset in screen-local SwiftUI coords is `+25` (downward),
    /// which in AppKit (y-up) is `-25`.
    private let cursorOffsetYFromMouseInAppKit: CGFloat = -25
    /// Half-width of the cursor triangle's bounding frame (16x16, so 8).
    private let cursorHalfWidth: CGFloat = 8
    /// Small visual gap between the cursor and the bubble's tail.
    private let gapBetweenCursorAndBubble: CGFloat = 4
    /// Where on the bubble's vertical axis the tail's TIP sits (0 = top
    /// of bubble, 1 = bottom). Must match `ChatBubbleShape.tailVerticalAnchor`
    /// in `ChatInputBubbleView.swift`. The position formula below uses this
    /// so that the tip — not the tail's geometric center — aligns with the
    /// cursor's vertical center, which is what the user perceives as "the
    /// tail is pointing at the cursor."
    private let tailVerticalAnchor: CGFloat = 0.18

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
        }
        mouseTrackingTimer?.invalidate()
    }

    /// Shows the chat bubble next to the AI cursor. If the bubble is
    /// already visible, this is a no-op (avoids stealing focus from a
    /// user who's already mid-type).
    func showBubble(
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        if let panel, panel.isVisible {
            return
        }

        let bubbleView = ChatInputBubbleView(
            onSubmit: { [weak self] submittedText in
                self?.hideBubble()
                onSubmit(submittedText)
            },
            onCancel: { [weak self] in
                self?.hideBubble()
                onCancel()
            }
        )
        .frame(width: panelWidth, height: panelHeight)

        let hostingView = NSHostingView(rootView: bubbleView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let bubblePanel = ChatInputBubblePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        bubblePanel.isFloatingPanel = true
        bubblePanel.level = .floating
        bubblePanel.isOpaque = false
        bubblePanel.backgroundColor = .clear
        bubblePanel.hasShadow = false
        bubblePanel.hidesOnDeactivate = false
        bubblePanel.isExcludedFromWindowsMenu = true
        bubblePanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        bubblePanel.isMovableByWindowBackground = false
        bubblePanel.titleVisibility = .hidden
        bubblePanel.titlebarAppearsTransparent = true
        bubblePanel.contentView = hostingView

        // Position the panel at the current mouse location before ordering
        // it in so it appears in the right place from frame zero.
        positionPanelToFollowCursor(bubblePanel, mouseLocation: NSEvent.mouseLocation)

        bubblePanel.makeKeyAndOrderFront(nil)
        bubblePanel.orderFrontRegardless()

        panel = bubblePanel
        installClickOutsideMonitor(onCancel: onCancel)
        installEscapeKeyMonitor(onCancel: onCancel)
        startMouseTracking()
    }

    /// Dismisses the bubble immediately. Safe to call when no bubble is shown.
    func hideBubble() {
        stopMouseTracking()
        panel?.orderOut(nil)
        panel = nil
        removeClickOutsideMonitor()
        removeEscapeKeyMonitor()
    }

    // MARK: - Position

    /// Places the panel so its tail points at the AI cursor (which itself
    /// sits at `mouseLocation + (35, -25)` in AppKit coords). The bubble's
    /// left edge sits just past the cursor's right edge with a small gap,
    /// and the tail's vertical anchor aligns with the cursor's vertical
    /// center so the tail looks like it's emerging directly from the cursor.
    /// Clamps to the active screen's visible frame so the bubble never
    /// lands off-screen, behind the menu bar, or under the dock.
    private func positionPanelToFollowCursor(_ panelToPosition: NSPanel, mouseLocation: NSPoint) {
        // Find which screen the mouse is currently on so we clamp against
        // the right display in a multi-monitor setup.
        let activeScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let activeScreen else { return }

        let visibleFrame = activeScreen.visibleFrame

        // Cursor center in AppKit coords (y-up).
        let cursorCenterX = mouseLocation.x + cursorOffsetXFromMouse
        let cursorCenterY = mouseLocation.y + cursorOffsetYFromMouseInAppKit

        // Place the panel's left edge just past the cursor's right edge
        // with a small visual gap. The panel.minX is exactly where the
        // bubble's tail tip sits in `ChatBubbleShape`, so this anchors the
        // tail right at the cursor.
        var panelOriginX = cursorCenterX + cursorHalfWidth + gapBetweenCursorAndBubble

        // Vertically position so the tail tip aligns with the cursor's
        // vertical center. In AppKit, panel.top = panelOriginY + panelHeight,
        // and the tail sits at `panelHeight * tailVerticalAnchor` below the
        // panel's top. So tail Y = panelOriginY + panelHeight * (1 - tailVerticalAnchor).
        // Setting that equal to cursorCenterY and solving:
        var panelOriginY = cursorCenterY - panelHeight * (1.0 - tailVerticalAnchor)

        // Clamp horizontally — if the bubble would run off the right edge,
        // place it to the LEFT of the cursor instead. (We don't bother
        // flipping the tail in that case — the bubble still reads as a chat
        // bubble; the tail just points the wrong way at edge cases.)
        if panelOriginX + panelWidth > visibleFrame.maxX {
            panelOriginX = max(visibleFrame.minX + 8, cursorCenterX - cursorHalfWidth - gapBetweenCursorAndBubble - panelWidth)
        }
        if panelOriginX < visibleFrame.minX {
            panelOriginX = visibleFrame.minX + 8
        }

        // Clamp vertically
        if panelOriginY < visibleFrame.minY {
            panelOriginY = visibleFrame.minY + 8
        }
        if panelOriginY + panelHeight > visibleFrame.maxY {
            panelOriginY = visibleFrame.maxY - panelHeight - 8
        }

        panelToPosition.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: panelHeight),
            display: true
        )
    }

    // MARK: - Mouse Tracking

    /// Starts a 60fps timer that keeps the bubble pinned next to the cursor
    /// as the user moves their mouse. Mirrors the cursor-following behavior
    /// in `OverlayWindow.BlueCursorView.startTrackingCursor()`.
    private func startMouseTracking() {
        stopMouseTracking()

        mouseTrackingTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            // Capture the manager weakly and the panel separately so the
            // timer doesn't keep them alive after `hideBubble()`.
            guard let self, let panel = self.panel else { return }
            let currentMouseLocation = NSEvent.mouseLocation
            self.positionPanelToFollowCursor(panel, mouseLocation: currentMouseLocation)
        }
    }

    private func stopMouseTracking() {
        mouseTrackingTimer?.invalidate()
        mouseTrackingTimer = nil
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that dismisses the bubble when the
    /// user clicks anywhere outside it. Same pattern used by
    /// `MenuBarPanelManager.installClickOutsideMonitor()`.
    private func installClickOutsideMonitor(onCancel: @escaping () -> Void) {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, let panel = self.panel else { return }

            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            self.hideBubble()
            onCancel()
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    // MARK: - Escape Key Dismissal

    /// Installs a *local* key-event monitor (fires only when the bubble's
    /// panel is the key window) that catches Escape and dismisses. macOS
    /// keycode 53 is Escape. Returning `nil` from the monitor swallows
    /// the event so the SwiftUI TextField doesn't also see it.
    private func installEscapeKeyMonitor(onCancel: @escaping () -> Void) {
        removeEscapeKeyMonitor()

        let escapeKeyCode: UInt16 = 53
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] keyEvent in
            guard keyEvent.keyCode == escapeKeyCode else {
                return keyEvent
            }
            self?.hideBubble()
            onCancel()
            // Returning nil consumes the event — the TextField never sees it.
            return nil
        }
    }

    private func removeEscapeKeyMonitor() {
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
        }
    }
}
