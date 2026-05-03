//
//  ProcessingShimmerManager.swift
//  leanring-buddy
//
//  Owns the full-screen shimmer overlay panels — one per connected
//  display — that render the Apple-Intelligence-style processing
//  animation. Each panel is borderless, transparent, click-through, and
//  sits at the screen-saver window level so the shimmer appears above
//  other windows without ever stealing focus or blocking interaction.
//
//  Show/hide is triggered from `CompanionManager` based on voice state
//  transitions — visible only while the AI is processing a request,
//  hidden the rest of the time so the screen edges aren't constantly
//  glowing.
//

import AppKit
import SwiftUI

/// Full-screen shimmer overlay window. Critically `ignoresMouseEvents`
/// is true so users can click through the colored edge glow to whatever
/// they were doing — the shimmer is purely visual feedback.
private final class ProcessingShimmerWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Transparent, non-interactive, always-on-top.
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // matches OverlayWindow so they coexist
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false
        self.hidesOnDeactivate = false

        // Cover the entire screen including menu bar / dock zones.
        self.setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ProcessingShimmerManager {
    /// One window per screen, keyed by `NSScreen.frame`.
    private var windowsByScreenFrame: [NSRect: ProcessingShimmerWindow] = [:]

    /// True while the shimmer is currently shown. Used to make `show()`
    /// idempotent — calling it while already visible is a no-op.
    private var isShimmerCurrentlyVisible = false

    /// Renders the shimmer on the screen the cursor is currently on.
    /// Idempotent: safe to call repeatedly without flicker. We pin to
    /// one screen rather than every connected display because the
    /// processing-feedback shimmer is meant to be a focused signal at
    /// the user's current attention, not a global "the system is busy"
    /// overlay across all monitors.
    func show() {
        guard !isShimmerCurrentlyVisible else { return }
        isShimmerCurrentlyVisible = true

        // Pick the cursor's current screen.
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen = targetScreen else { return }

        // Hide any windows on OTHER screens — happens if the user moves
        // between monitors between chat sessions.
        for (frame, oldWindow) in windowsByScreenFrame where frame != screen.frame {
            oldWindow.orderOut(nil)
            oldWindow.contentView = nil
        }

        let window = windowsByScreenFrame[screen.frame] ?? createWindow(for: screen)
        windowsByScreenFrame[screen.frame] = window

        // (Re-)install the SwiftUI hosting view. Doing this on every
        // show means the rotation animation restarts from 0° each
        // request, which feels intentional — the shimmer "powers on"
        // when processing begins rather than picking up mid-rotation
        // from a previous run.
        let hostingView = NSHostingView(rootView: ProcessingShimmerView())
        hostingView.frame = NSRect(origin: .zero, size: screen.frame.size)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        window.contentView = hostingView

        window.orderFrontRegardless()
    }

    /// Tears down all shimmer windows. Safe to call when no shimmer is
    /// shown.
    func hide() {
        guard isShimmerCurrentlyVisible else { return }
        isShimmerCurrentlyVisible = false

        for window in windowsByScreenFrame.values {
            window.orderOut(nil)
            // Drop the contentView so the SwiftUI view's animation
            // timers stop running while the window is hidden — otherwise
            // they'd churn CPU even when nothing is on screen.
            window.contentView = nil
        }
    }

    private func createWindow(for screen: NSScreen) -> ProcessingShimmerWindow {
        ProcessingShimmerWindow(screen: screen)
    }
}
