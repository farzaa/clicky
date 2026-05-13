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

private final class SubagentDotLaunchAnimationPanel: NSPanel {
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
    private var launchAnimationPanels: [NSPanel] = []
    private var combineCancellables: Set<AnyCancellable> = []
    private var hasCapturedInitialVisibleDotIDs = false
    private var knownAgentTaskIDsForLaunchAnimation: Set<UUID> = []
    private var knownVideoMonitorTaskIDsForLaunchAnimation: Set<String> = []

    private let overlayWidth: CGFloat = 68
    private let rightEdgeMargin: CGFloat = 10
    private let topEdgeMarginUnderMenuBar: CGFloat = 46
    private let minimumOverlayHeight: CGFloat = 72
    private let approximateHeightPerDot: CGFloat = 46
    private let dotStackTopPadding: CGFloat = 10
    private let dotStackTrailingPadding: CGFloat = 10
    private let dotButtonSideLength: CGFloat = 46
    private let dotStackSpacing: CGFloat = 10

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
                let visibleAgentTasks = runningTasks + recentlyFinishedTasks
                if visibleAgentTasks.isEmpty {
                    if activeVideoMonitors.isEmpty {
                        self.hideOverlay()
                    } else {
                        self.ensureOverlayIsVisible()
                    }
                } else {
                    self.ensureOverlayIsVisible()
                }
                self.playLaunchAnimationsForNewVisibleDots(
                    visibleAgentTasks: visibleAgentTasks,
                    activeVideoMonitors: activeVideoMonitors
                )
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

    private func playLaunchAnimationsForNewVisibleDots(
        visibleAgentTasks: [AgentTask],
        activeVideoMonitors: [VideoMemoryMonitor]
    ) {
        let currentAgentTaskIDs = Set(visibleAgentTasks.map(\.id))
        let currentVideoMonitorTaskIDs = Set(activeVideoMonitors.map(\.taskID))

        defer {
            knownAgentTaskIDsForLaunchAnimation = currentAgentTaskIDs
            knownVideoMonitorTaskIDsForLaunchAnimation = currentVideoMonitorTaskIDs
            hasCapturedInitialVisibleDotIDs = true
        }

        guard hasCapturedInitialVisibleDotIDs else { return }

        let newAgentTasks = visibleAgentTasks.filter { task in
            knownAgentTaskIDsForLaunchAnimation.contains(task.id) == false
        }
        let newVideoMonitors = activeVideoMonitors.filter { monitor in
            knownVideoMonitorTaskIDsForLaunchAnimation.contains(monitor.taskID) == false
        }
        guard !newAgentTasks.isEmpty || !newVideoMonitors.isEmpty else { return }

        ensureOverlayIsVisible()
        guard let overlayPanelFrame = hostedPanel?.frame else { return }
        let launchStartPoint = currentDotLaunchStartPoint()

        for newAgentTask in newAgentTasks {
            guard let dotIndex = visibleAgentTasks.firstIndex(where: { $0.id == newAgentTask.id }) else {
                continue
            }
            playLaunchAnimation(
                startScreenPoint: launchStartPoint,
                endScreenPoint: dotCenterScreenPoint(
                    dotIndex: dotIndex,
                    overlayPanelFrame: overlayPanelFrame
                ),
                dotColor: SubagentDotVisualPalette.colorForTaskID(newAgentTask.id)
            )
        }

        for newVideoMonitor in newVideoMonitors {
            guard let videoMonitorIndex = activeVideoMonitors.firstIndex(where: { $0.taskID == newVideoMonitor.taskID }) else {
                continue
            }
            let dotIndex = visibleAgentTasks.count + videoMonitorIndex
            playLaunchAnimation(
                startScreenPoint: launchStartPoint,
                endScreenPoint: dotCenterScreenPoint(
                    dotIndex: dotIndex,
                    overlayPanelFrame: overlayPanelFrame
                ),
                dotColor: SubagentDotVisualPalette.colorForVideoMonitorTaskID(newVideoMonitor.taskID)
            )
        }
    }

    private func currentDotLaunchStartPoint() -> CGPoint {
        let mouseLocation = NSEvent.mouseLocation
        let proposedStartPoint = CGPoint(
            x: mouseLocation.x + 35,
            y: mouseLocation.y - 25
        )
        let activeScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let activeScreen else { return proposedStartPoint }
        let clampedFrame = activeScreen.frame.insetBy(dx: 24, dy: 24)
        return CGPoint(
            x: min(max(proposedStartPoint.x, clampedFrame.minX), clampedFrame.maxX),
            y: min(max(proposedStartPoint.y, clampedFrame.minY), clampedFrame.maxY)
        )
    }

    private func dotCenterScreenPoint(dotIndex: Int, overlayPanelFrame: CGRect) -> CGPoint {
        let finalLocalX = overlayWidth - dotStackTrailingPadding - (dotButtonSideLength / 2)
        let finalLocalY = dotStackTopPadding
            + CGFloat(dotIndex) * (dotButtonSideLength + dotStackSpacing)
            + (dotButtonSideLength / 2)

        return CGPoint(
            x: overlayPanelFrame.minX + finalLocalX,
            y: overlayPanelFrame.maxY - finalLocalY
        )
    }

    private func playLaunchAnimation(
        startScreenPoint: CGPoint,
        endScreenPoint: CGPoint,
        dotColor: Color
    ) {
        guard let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(endScreenPoint) })
                ?? NSScreen.main
                ?? NSScreen.screens.first else {
            return
        }

        DotDebugLogger.log("subagent.overlay", "starting launch animation", metadata: [
            "startX": Double(startScreenPoint.x),
            "startY": Double(startScreenPoint.y),
            "endX": Double(endScreenPoint.x),
            "endY": Double(endScreenPoint.y)
        ])

        let panel = SubagentDotLaunchAnimationPanel(
            contentRect: targetScreen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        let launchView = SubagentDotLaunchFlightView(
            screenFrame: targetScreen.frame,
            startScreenPoint: startScreenPoint,
            endScreenPoint: endScreenPoint,
            dotColor: dotColor,
            onAnimationCompleted: { [weak self, weak panel] in
                guard let self, let panel else { return }
                panel.orderOut(nil)
                panel.contentView = nil
                self.launchAnimationPanels.removeAll { $0 === panel }
            }
        )

        let hostingView = NSHostingView(rootView: launchView)
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: targetScreen.frame.width,
            height: targetScreen.frame.height
        )
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        panel.contentView = hostingView

        launchAnimationPanels.append(panel)
        panel.orderFrontRegardless()
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

private struct SubagentDotLaunchFlightView: View {
    let screenFrame: CGRect
    let startScreenPoint: CGPoint
    let endScreenPoint: CGPoint
    let dotColor: Color
    let onAnimationCompleted: () -> Void

    @State private var progress: CGFloat = 0
    @State private var hasScheduledCompletion = false

    private let animationDurationSeconds: TimeInterval = 0.72

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)

            ForEach(1...4, id: \.self) { ghostIndex in
                let ghostProgress = max(0, progress - CGFloat(ghostIndex) * 0.045)
                Circle()
                    .fill(dotColor.opacity(0.46 - Double(ghostIndex) * 0.08))
                    .frame(width: 17, height: 17)
                    .blur(radius: CGFloat(ghostIndex) * 0.6)
                    .scaleEffect(max(0.45, 1.0 - CGFloat(ghostIndex) * 0.11))
                    .opacity(ghostOpacity(for: ghostIndex))
                    .position(pointAlongFlight(progress: ghostProgress))
            }

            Circle()
                .fill(dotColor)
                .frame(width: 18, height: 18)
                .shadow(color: dotColor.opacity(0.75), radius: 11, x: 0, y: 0)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.62), lineWidth: 1)
                )
                .scaleEffect(CGFloat(0.72 + sin(Double(progress) * .pi) * 0.52))
                .position(pointAlongFlight(progress: progress))
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onAppear {
            guard !hasScheduledCompletion else { return }
            hasScheduledCompletion = true
            withAnimation(.timingCurve(0.18, 0.78, 0.18, 1.0, duration: animationDurationSeconds)) {
                progress = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + animationDurationSeconds + 0.08) {
                onAnimationCompleted()
            }
        }
    }

    private func ghostOpacity(for ghostIndex: Int) -> Double {
        let fadeOutProgress = max(0, min(1, (progress - 0.86) / 0.14))
        let birthProgress = min(1, Double(progress) * 2.5)
        return birthProgress * (1 - Double(ghostIndex) * 0.15) * (1 - Double(fadeOutProgress))
    }

    private func pointAlongFlight(progress rawProgress: CGFloat) -> CGPoint {
        let clampedProgress = min(max(rawProgress, 0), 1)
        let startPoint = localPoint(for: startScreenPoint)
        let endPoint = localPoint(for: endScreenPoint)

        let deltaX = endPoint.x - startPoint.x
        let deltaY = endPoint.y - startPoint.y
        let distance = hypot(deltaX, deltaY)
        let midpoint = CGPoint(
            x: (startPoint.x + endPoint.x) / 2,
            y: (startPoint.y + endPoint.y) / 2
        )
        let arcLift = min(max(distance * 0.16, 36), 120)
        let controlPoint = CGPoint(
            x: midpoint.x,
            y: midpoint.y - arcLift
        )

        let oneMinusProgress = 1 - clampedProgress
        let x = oneMinusProgress * oneMinusProgress * startPoint.x
            + 2 * oneMinusProgress * clampedProgress * controlPoint.x
            + clampedProgress * clampedProgress * endPoint.x
        let y = oneMinusProgress * oneMinusProgress * startPoint.y
            + 2 * oneMinusProgress * clampedProgress * controlPoint.y
            + clampedProgress * clampedProgress * endPoint.y
        return CGPoint(x: x, y: y)
    }

    private func localPoint(for screenPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: screenPoint.x - screenFrame.minX,
            y: screenFrame.maxY - screenPoint.y
        )
    }
}
