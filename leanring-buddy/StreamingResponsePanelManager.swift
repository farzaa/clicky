//
//  StreamingResponsePanelManager.swift
//  leanring-buddy
//
//  Manages the floating chat panel for text-mode interactions — the
//  rounded dark panel anchored at top-right of every screen that hosts
//  the user ↔ Clicky conversation. Each panel is its own NSPanel because
//  the cursor overlay is `ignoresMouseEvents = true` and would have
//  swallowed clicks on the close button or the follow-up input field.
//
//  Panels observe `CompanionManager` directly via `@ObservedObject`, so
//  the manager doesn't need to push every text-chunk update — SwiftUI's
//  diffing re-renders the chat as `streamingResponseText`,
//  `conversationHistory`, and `pendingUserPrompt` change.
//
//  Behavior:
//    - One NSPanel per connected screen, all showing the same chat.
//    - Positioned top-right of `screen.visibleFrame` so it doesn't sit
//      on top of the menu bar.
//    - Slides further down when the mouse hovers the menu bar zone, so
//      the user can interact with menu items without the panel covering
//      them.
//    - Non-activating: the panel can become key (so the input field
//      gets focus) without stealing focus from the user's current app.
//

import AppKit
import Combine
import SwiftUI

/// Subclass overriding `canBecomeKey` so the SwiftUI `TextField` inside
/// the chat input row can become first responder. Without this, key
/// presses inside a non-activating panel are silently dropped.
private final class StreamingResponsePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Thin SwiftUI wrapper that observes `CompanionManager` and feeds the
/// observable state into `StreamingResponsePanelView`. Lives here so the
/// view itself stays a pure data → UI mapping (easier to preview and
/// reason about).
private struct StreamingResponsePanelHost: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        StreamingResponsePanelView(
            conversationHistory: companionManager.conversationHistory,
            pendingUserPrompt: companionManager.pendingUserPrompt,
            streamingResponseText: companionManager.streamingResponseText,
            // We're "processing" from the moment the user submits until
            // the assistant response is committed to history. During the
            // streaming window `streamingResponseText` is non-empty AND
            // `pendingUserPrompt` is still set, so this flag toggles to
            // false only once `pendingUserPrompt` clears.
            isProcessingCurrentTurn: companionManager.pendingUserPrompt != nil,
            onSubmitFollowUp: { followUpText in
                companionManager.submitTextInput(followUpText)
            },
            onDismiss: {
                companionManager.dismissStreamingResponse()
            }
        )
    }
}

@MainActor
final class StreamingResponsePanelManager {
    /// One panel per connected screen, keyed by `NSScreen.frame`.
    private var panelsByScreenFrame: [NSRect: StreamingResponsePanel] = [:]

    /// Polling timer that keeps each panel's vertical position in sync
    /// with whether the mouse is hovering the menu bar zone.
    private var mouseTrackingTimer: Timer?

    /// Combine subscriptions on the @Published state we want the panel
    /// to react to. Belt-and-suspenders: even if `@ObservedObject`
    /// inside the SwiftUI host view weren't propagating updates, these
    /// force a manual rootView reassignment on every change.
    private var stateSubscriptions: Set<AnyCancellable> = []

    /// Vertical inset from the screen's visible-frame top in normal state.
    private let normalTopInset: CGFloat = 12

    /// Vertical inset when the mouse is in the menu bar zone — slides
    /// the panel down further so it doesn't cover menu items.
    private let menuBarHoverTopInset: CGFloat = 48

    /// Horizontal inset from the screen's visible-frame right edge.
    private let trailingInset: CGFloat = 16

    /// How tall the menu-bar trigger zone is. Slightly taller than the
    /// actual menu bar so the slide-down kicks in as the mouse approaches.
    private let menuBarTriggerZoneHeight: CGFloat = 36

    deinit {
        mouseTrackingTimer?.invalidate()
        // `stateSubscriptions` clears automatically when the manager
        // deinits, but being explicit avoids a stray reference if a
        // subscription's sink closure captured something we care about.
        stateSubscriptions.removeAll()
    }

    // MARK: - Public API

    /// Shows the chat panel on every connected screen, bound to the
    /// given `CompanionManager`. Idempotent — calling while already
    /// shown is a no-op for panel creation, but ensures the SwiftUI
    /// hosting view is up-to-date.
    func show(companionManager: CompanionManager) {
        // Pin the chat to the screen the cursor is on at the moment of
        // show. We deliberately don't follow the cursor across screens
        // mid-chat — moving panels under the user as they drag their
        // mouse to another monitor would feel jarring. Lock to one.
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen = targetScreen else { return }

        // Tear down any panels we have on OTHER screens — happens if
        // the user dismissed and re-summoned on a different monitor.
        for (frame, oldPanel) in panelsByScreenFrame where frame != screen.frame {
            oldPanel.orderOut(nil)
            oldPanel.contentView = nil
        }
        panelsByScreenFrame = panelsByScreenFrame.filter { $0.key == screen.frame }

        let panel = panelsByScreenFrame[screen.frame] ?? createPanel(for: screen)
        panelsByScreenFrame[screen.frame] = panel

        // Always (re)install the hosting view on every show. This
        // guarantees a fresh `@ObservedObject` binding to the
        // current `companionManager` rather than relying on a
        // potentially stale view tree from a previous chat session.
        installContentView(panel: panel, companionManager: companionManager)

        // Initial sizing + positioning. After this, the timer only
        // touches origin and the Combine sinks handle resizing on
        // content changes.
        resizePanelToFitContent(panel, on: screen)
        repositionPanel(panel, on: screen, mouseLocation: mouseLocation)
        // makeKeyAndOrderFront orders the window front AND makes it
        // key in one shot — this is what's needed for the input
        // field to actually receive focus. Calling makeKey() alone
        // (without ordering) leaves the panel behind other windows.
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()

        startMouseTracking()
        startObservingCompanionState(companionManager: companionManager)
    }

    /// Tears down all panels and stops the mouse-tracking timer. Safe to
    /// call when no panel is shown.
    func hide() {
        stopMouseTracking()
        stateSubscriptions.removeAll()
        for panel in panelsByScreenFrame.values {
            panel.orderOut(nil)
            // Drop the SwiftUI hosting view so its observers are released
            // and any in-flight animations stop. Recreated on next show().
            panel.contentView = nil
        }
        panelsByScreenFrame.removeAll()
    }

    /// Compatibility shim — the chat panel observes `CompanionManager`
    /// directly now, so callers don't need to push text chunks. Kept as
    /// a no-op so existing call sites don't break.
    func updateResponseText(_ text: String) {
        // Intentionally empty — see class doc comment.
    }

    // MARK: - Combine-driven Refresh (defensive)

    /// Subscribes to the @Published properties the chat panel cares
    /// about and forces a manual rootView reassignment on every change.
    /// This duplicates work that `@ObservedObject` should already be
    /// doing, but in practice `@ObservedObject` propagation through
    /// `NSHostingView` can be unreliable when the hosting view is set
    /// up imperatively from AppKit code (vs. declaratively in a SwiftUI
    /// hierarchy). Re-assigning `rootView` is cheap and guarantees the
    /// panel never goes stale.
    private func startObservingCompanionState(companionManager: CompanionManager) {
        stateSubscriptions.removeAll()

        let refresh: (String) -> Void = { [weak self] reason in
            guard let self else { return }
            // Single source of truth for "state changed" logging — fires
            // exactly once per @Published change, in contrast to a print
            // inside `body` which fires on every body re-evaluation.
            print("🔍 State change (\(reason)): pending=\(companionManager.pendingUserPrompt ?? "nil"), streaming=\(companionManager.streamingResponseText.count)c, history=\(companionManager.conversationHistory.count)")
            self.refreshAllRootViews(companionManager: companionManager)
        }

        companionManager.$conversationHistory
            .dropFirst()  // skip the initial value emitted on subscribe
            .receive(on: DispatchQueue.main)
            .sink { _ in refresh("history") }
            .store(in: &stateSubscriptions)

        companionManager.$pendingUserPrompt
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in refresh("pending") }
            .store(in: &stateSubscriptions)

        companionManager.$streamingResponseText
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in refresh("streaming") }
            .store(in: &stateSubscriptions)
    }

    /// Reassigns the SwiftUI rootView on every panel and re-fits the
    /// panel size to the new content. Called only on actual @Published
    /// state changes, not on every mouse-tracking tick.
    private func refreshAllRootViews(companionManager: CompanionManager) {
        for (screenFrame, panel) in panelsByScreenFrame {
            guard let hostingView = panel.contentView as? NSHostingView<StreamingResponsePanelHost> else {
                continue
            }
            hostingView.rootView = StreamingResponsePanelHost(companionManager: companionManager)
            hostingView.layoutSubtreeIfNeeded()

            // Resize to match the new content's natural size.
            if let screen = NSScreen.screens.first(where: { $0.frame == screenFrame }) {
                resizePanelToFitContent(panel, on: screen)
            }
        }
    }

    // MARK: - Panel Creation

    private func createPanel(for screen: NSScreen) -> StreamingResponsePanel {
        let panel = StreamingResponsePanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: StreamingResponsePanelView.panelWidth,
                height: 200
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        return panel
    }

    private func installContentView(panel: StreamingResponsePanel, companionManager: CompanionManager) {
        let hostingView = NSHostingView(rootView: StreamingResponsePanelHost(companionManager: companionManager))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        // Set a generous initial size. `hostingView.fittingSize` returns
        // (0, 0) before SwiftUI has run its layout pass, which would
        // make the panel 0×0 and silently invisible. We start at a
        // reasonable size and let the mouse-tracking timer's
        // `positionPanel` calls re-measure and resize on each tick once
        // SwiftUI has actually laid out the content.
        let initialSize = NSSize(
            width: StreamingResponsePanelView.panelWidth,
            height: 200
        )
        hostingView.frame = NSRect(origin: .zero, size: initialSize)
        panel.contentView = hostingView
        panel.setContentSize(initialSize)

        // Force an immediate layout pass so the very first
        // `positionPanel` call after this returns the right fitting
        // size, rather than the placeholder we just set.
        hostingView.layoutSubtreeIfNeeded()
    }

    // MARK: - Position & Size
    //
    // Reposition and resize are split into two paths to prevent a
    // SwiftUI layout-feedback loop. The mouse-tracking timer fires
    // every 50ms; if it kept re-measuring `panel.contentView?.fittingSize`
    // each tick, that read could subtly shift SwiftUI's layout, which
    // would change the next fittingSize, ad infinitum — body re-evaluating
    // dozens of times per second with no actual state change.
    //
    // Now: `repositionPanel(_:on:mouseLocation:)` only updates origin,
    // using whatever the panel's *current* size is. Resizing happens
    // exclusively in `resizePanelToFitContent(_:on:)`, called from the
    // Combine subscriptions when the chat state actually changes.

    /// Updates the panel's origin to keep it pinned at top-right of the
    /// screen's visible frame, sliding down when the mouse hovers the
    /// menu bar zone. Does NOT change the panel's size.
    private func repositionPanel(_ panel: StreamingResponsePanel, on screen: NSScreen, mouseLocation: NSPoint) {
        let visibleFrame = screen.visibleFrame
        let isMouseInMenuBarZone = isMouseHoveringMenuBar(on: screen, mouseLocation: mouseLocation)
        let topInset = isMouseInMenuBarZone ? menuBarHoverTopInset : normalTopInset

        // Use the panel's CURRENT size — don't query fittingSize here.
        let currentSize = panel.frame.size
        let panelOriginX = visibleFrame.maxX - currentSize.width - trailingInset
        let panelOriginY = visibleFrame.maxY - currentSize.height - topInset

        let targetOrigin = NSPoint(x: panelOriginX, y: panelOriginY)

        if panel.frame.origin != targetOrigin {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrameOrigin(targetOrigin)
            }
        }
    }

    /// Re-measures `fittingSize` and resizes the panel to match. Called
    /// from the Combine subscriptions when the chat content changes —
    /// not from the timer. After resizing, also nudges the origin so the
    /// panel stays anchored at top-right (since growing height would
    /// otherwise push the panel below the visible frame).
    private func resizePanelToFitContent(_ panel: StreamingResponsePanel, on screen: NSScreen) {
        let measured = panel.contentView?.fittingSize ?? .zero
        let contentSize = NSSize(
            width: max(measured.width, StreamingResponsePanelView.panelWidth),
            height: max(measured.height, 120)
        )

        // Skip if nothing changed — avoids unnecessary layout passes.
        if abs(panel.frame.size.width - contentSize.width) < 0.5
            && abs(panel.frame.size.height - contentSize.height) < 0.5 {
            return
        }

        let visibleFrame = screen.visibleFrame
        let mouseLocation = NSEvent.mouseLocation
        let topInset = isMouseHoveringMenuBar(on: screen, mouseLocation: mouseLocation)
            ? menuBarHoverTopInset
            : normalTopInset

        let targetFrame = NSRect(
            x: visibleFrame.maxX - contentSize.width - trailingInset,
            y: visibleFrame.maxY - contentSize.height - topInset,
            width: contentSize.width,
            height: contentSize.height
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    private func isMouseHoveringMenuBar(on screen: NSScreen, mouseLocation: NSPoint) -> Bool {
        let screenFrame = screen.frame
        guard screenFrame.contains(mouseLocation) else { return false }
        let menuBarBandLowerBound = screenFrame.maxY - menuBarTriggerZoneHeight
        return mouseLocation.y >= menuBarBandLowerBound
    }

    // MARK: - Mouse Tracking

    private func startMouseTracking() {
        stopMouseTracking()

        // Timer only updates ORIGIN — never size. This was the source
        // of the runaway re-render loop where querying fittingSize on
        // every tick caused SwiftUI to re-layout, which changed
        // fittingSize again, infinitely.
        mouseTrackingTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let mouseLocation = NSEvent.mouseLocation
            for (screenFrame, panel) in self.panelsByScreenFrame {
                guard let screen = NSScreen.screens.first(where: { $0.frame == screenFrame }) else {
                    continue
                }
                self.repositionPanel(panel, on: screen, mouseLocation: mouseLocation)
            }
        }
    }

    private func stopMouseTracking() {
        mouseTrackingTimer?.invalidate()
        mouseTrackingTimer = nil
    }
}
