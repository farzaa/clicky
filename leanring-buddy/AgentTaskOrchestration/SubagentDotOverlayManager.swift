//
//  SubagentDotOverlayManager.swift
//  leanring-buddy
//
//  Hosts the transparent right-edge dot stack for background coding agents.
//  The dots are the lightweight entry point; clicking one opens the selected
//  task's detail panel.
//

import AppKit
import Combine
import SwiftUI

private final class SubagentDotOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SubagentDotOverlayManager: NSObject {

    private let agentTaskManager: AgentTaskManager
    private let videoMemoryMonitorManager: VideoMemoryMonitorManager
    private let agentTaskPanelManager: AgentTaskPanelManager
    private var hostedPanel: NSPanel?
    private var hostingView: NSHostingView<SubagentDotOverlayView>?
    private var combineCancellables: Set<AnyCancellable> = []

    private let overlayWidth: CGFloat = 68
    private let rightEdgeMargin: CGFloat = 10
    private let topEdgeMarginUnderMenuBar: CGFloat = 46
    private let minimumOverlayHeight: CGFloat = 72
    private let approximateHeightPerDot: CGFloat = 46

    init(
        agentTaskManager: AgentTaskManager,
        videoMemoryMonitorManager: VideoMemoryMonitorManager,
        agentTaskPanelManager: AgentTaskPanelManager
    ) {
        self.agentTaskManager = agentTaskManager
        self.videoMemoryMonitorManager = videoMemoryMonitorManager
        self.agentTaskPanelManager = agentTaskPanelManager
        super.init()
        observeTaskCollections()
    }

    private func observeTaskCollections() {
        agentTaskManager.$runningTasks
            .combineLatest(agentTaskManager.$recentlyFinishedTasks)
            .combineLatest(videoMemoryMonitorManager.$activeMonitors)
            .receive(on: RunLoop.main)
            .sink { [weak self] taskCollections, activeVideoMonitors in
                guard let self else { return }
                let (runningTasks, recentlyFinishedTasks) = taskCollections
                if runningTasks.isEmpty && recentlyFinishedTasks.isEmpty {
                    if activeVideoMonitors.isEmpty {
                        self.hideOverlay()
                    } else {
                        self.ensureOverlayIsVisible()
                    }
                } else {
                    self.ensureOverlayIsVisible()
                }
            }
            .store(in: &combineCancellables)
    }

    private func ensureOverlayIsVisible() {
        if hostedPanel == nil {
            createOverlay()
        }
        positionOverlayAtRightEdge()
        hostedPanel?.orderFrontRegardless()
    }

    private func hideOverlay() {
        hostedPanel?.orderOut(nil)
    }

    private func createOverlay() {
        let overlayRootView = SubagentDotOverlayView(
            agentTaskManager: agentTaskManager,
            videoMemoryMonitorManager: videoMemoryMonitorManager,
            onTaskSelected: { [weak self] selectedTaskID in
                self?.agentTaskPanelManager.showPanel(for: selectedTaskID)
            },
            onTaskDeleted: { [weak self] task in
                Task { @MainActor in
                    await self?.agentTaskManager.deleteTask(taskID: task.id)
                    self?.agentTaskPanelManager.hidePanel()
                }
            },
            onVideoMonitorSelected: { [weak self] monitor in
                self?.videoMemoryMonitorManager.openTaskPage(taskID: monitor.taskID)
            },
            onVideoMonitorStopped: { [weak self] monitor in
                Task { @MainActor in
                    _ = await self?.videoMemoryMonitorManager.stopMonitor(taskID: monitor.taskID)
                }
            }
        )

        let hostingView = NSHostingView(rootView: overlayRootView)
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: overlayWidth,
            height: minimumOverlayHeight
        )
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let panel = SubagentDotOverlayPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: overlayWidth,
                height: minimumOverlayHeight
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
        panel.contentView = hostingView

        self.hostedPanel = panel
        self.hostingView = hostingView
    }

    private func positionOverlayAtRightEdge() {
        guard let panel = hostedPanel else { return }
        let mouseLocation = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let chosenScreen = activeScreen else { return }

        let visibleFrame = chosenScreen.visibleFrame
        let visibleTaskCount = max(
            1,
            agentTaskManager.visibleTasksForSubagentDots.count
                + videoMemoryMonitorManager.activeMonitorCountForOverlay
        )
        let desiredOverlayHeight = CGFloat(visibleTaskCount) * approximateHeightPerDot + 20
        let maxOverlayHeight = max(minimumOverlayHeight, visibleFrame.height - 100)
        let resolvedOverlayHeight = min(maxOverlayHeight, max(minimumOverlayHeight, desiredOverlayHeight))

        let overlayOriginX = visibleFrame.maxX - overlayWidth - rightEdgeMargin
        let overlayOriginY = visibleFrame.maxY - resolvedOverlayHeight - topEdgeMarginUnderMenuBar

        panel.setFrame(
            NSRect(
                x: overlayOriginX,
                y: overlayOriginY,
                width: overlayWidth,
                height: resolvedOverlayHeight
            ),
            display: true
        )
        hostingView?.frame = NSRect(
            x: 0,
            y: 0,
            width: overlayWidth,
            height: resolvedOverlayHeight
        )
    }
}
