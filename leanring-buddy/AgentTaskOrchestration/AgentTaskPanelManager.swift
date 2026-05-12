//
//  AgentTaskPanelManager.swift
//  leanring-buddy
//
//  Owns the right-edge floating NSPanel that hosts AgentTaskPanelView. The
//  subagent dot overlay calls `showPanel(for:)` when the user clicks a task
//  dot; this panel is only the selected task's detail surface.
//

import AppKit
import SwiftUI

private class AgentTaskKeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AgentTaskPanelSelection: ObservableObject {
    @Published var selectedTaskID: UUID?
}

@MainActor
final class AgentTaskPanelManager: NSObject {

    private let agentTaskManager: AgentTaskManager
    private let panelSelection = AgentTaskPanelSelection()
    private var hostedPanel: NSPanel?
    private var hostingView: NSHostingView<AgentTaskPanelView>?

    private let panelWidth: CGFloat = 380
    private let panelMinimumHeight: CGFloat = 150
    private let panelMaximumHeight: CGFloat = 420
    /// Leaves room for the right-edge subagent dots so the detail panel does
    /// not render underneath the clickable dot stack.
    private let panelRightEdgeMargin: CGFloat = 92
    private let panelTopEdgeMarginUnderMenuBar: CGFloat = 36

    init(agentTaskManager: AgentTaskManager) {
        self.agentTaskManager = agentTaskManager
        super.init()
    }

    // MARK: - Public surface

    func showPanel(for taskID: UUID) {
        panelSelection.selectedTaskID = taskID
        if hostedPanel == nil {
            createPanel()
        }
        positionPanelAtRightEdge()
        hostedPanel?.orderFrontRegardless()
    }

    func hidePanel() {
        hostedPanel?.orderOut(nil)
    }

    // MARK: - Panel construction

    private func createPanel() {
        let panelRootView = AgentTaskPanelView(
            agentTaskManager: agentTaskManager,
            panelSelection: panelSelection,
            onCancelTaskRequested: { [weak self] task in
                Task { @MainActor in
                    await self?.agentTaskManager.cancelTask(taskID: task.id)
                }
            },
            onCloseRequested: { [weak self] in
                self?.hidePanel()
            }
        )

        let hostingView = NSHostingView(rootView: panelRootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelMinimumHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let panel = AgentTaskKeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelMinimumHeight),
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
            ?? CGSize(width: panelWidth, height: panelMinimumHeight)
        let resolvedPanelHeight = max(panelMinimumHeight, min(panelMaximumHeight, fittingSize.height))

        let visibleFrame = chosenScreen.visibleFrame
        let panelOriginX = visibleFrame.maxX - panelWidth - panelRightEdgeMargin
        let panelOriginY = visibleFrame.maxY - resolvedPanelHeight - panelTopEdgeMarginUnderMenuBar

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: resolvedPanelHeight),
            display: true
        )
    }
}
