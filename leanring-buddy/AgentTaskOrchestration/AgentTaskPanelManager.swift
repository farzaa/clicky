//
//  AgentTaskPanelManager.swift
//  leanring-buddy
//
//  Owns the right-edge floating NSPanel that hosts AgentTaskPanelView. Same
//  NSPanel pattern as MenuBarPanelManager: borderless, nonactivating,
//  floating level, joins all spaces. Auto-shows when a task starts and
//  auto-hides 5s after the last task completes (unless the user keeps it
//  open).
//

import AppKit
import Combine
import SwiftUI

private class AgentTaskKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AgentTaskPanelManager: NSObject {

    private let agentTaskManager: AgentTaskManager
    private var hostedPanel: NSPanel?
    private var hostingView: NSHostingView<AgentTaskPanelView>?

    /// Cancellable subscriptions watching the task manager so we can auto-
    /// show when a task starts and auto-hide a few seconds after it finishes.
    private var combineCancellables: Set<AnyCancellable> = []
    private var autoHideTask: Task<Void, Never>?

    private let panelWidth: CGFloat = 380
    private let panelRightEdgeMargin: CGFloat = 16
    private let panelTopEdgeMarginUnderMenuBar: CGFloat = 36

    init(agentTaskManager: AgentTaskManager) {
        self.agentTaskManager = agentTaskManager
        super.init()
        observeAgentTaskManagerStateChanges()
    }

    // MARK: - Public surface

    /// Called by AgentTaskManager when something changes that should make
    /// the panel visible. Idempotent — already-visible panels stay visible.
    func ensurePanelIsVisible() {
        if hostedPanel == nil {
            createPanel()
        }
        positionPanelAtRightEdge()
        hostedPanel?.orderFrontRegardless()
        cancelAutoHide()
    }

    func hidePanel() {
        hostedPanel?.orderOut(nil)
        cancelAutoHide()
    }

    // MARK: - Auto-show / auto-hide

    private func observeAgentTaskManagerStateChanges() {
        // Show whenever a task appears.
        agentTaskManager.$currentTask
            .receive(on: RunLoop.main)
            .sink { [weak self] runningTaskOrNil in
                guard let self else { return }
                if runningTaskOrNil != nil {
                    self.ensurePanelIsVisible()
                } else {
                    // Task ended — leave panel visible briefly so user sees
                    // the result, then auto-hide.
                    self.scheduleAutoHide()
                }
            }
            .store(in: &combineCancellables)
    }

    private func scheduleAutoHide() {
        cancelAutoHide()
        autoHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            // Only hide if there's still no active task. A new task started
            // during the grace window cancels this.
            if self.agentTaskManager.currentTask == nil {
                self.hidePanel()
            }
        }
    }

    private func cancelAutoHide() {
        autoHideTask?.cancel()
        autoHideTask = nil
    }

    // MARK: - Panel construction

    private func createPanel() {
        let panelRootView = AgentTaskPanelView(
            agentTaskManager: agentTaskManager,
            onCloseRequested: { [weak self] in
                self?.hidePanel()
            }
        )

        let hostingView = NSHostingView(rootView: panelRootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: 220)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let panel = AgentTaskKeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.contentView = hostingView

        self.hostedPanel = panel
        self.hostingView = hostingView
    }

    /// Anchors the panel to the right edge of the screen that currently
    /// contains the mouse cursor (so multi-monitor setups put the panel on
    /// the screen the user is actively working on). Top edge sits just
    /// below the menu bar.
    private func positionPanelAtRightEdge() {
        guard let panel = hostedPanel else { return }
        let mouseLocation = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let chosenScreen = activeScreen else { return }

        let fittingSize = panel.contentView?.fittingSize
            ?? CGSize(width: panelWidth, height: 320)
        let resolvedPanelHeight = max(220, min(620, fittingSize.height))

        let visibleFrame = chosenScreen.visibleFrame
        let panelOriginX = visibleFrame.maxX - panelWidth - panelRightEdgeMargin
        let panelOriginY = visibleFrame.maxY - resolvedPanelHeight - panelTopEdgeMarginUnderMenuBar

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: resolvedPanelHeight),
            display: true
        )
    }
}
