//
//  ContextCircleManager.swift
//  leanring-buddy
//
//  Non-activating floating context circle. It toggles a compact context
//  editor popup and accepts dropped files without taking app focus.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

private final class ContextCirclePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ContextCircleManager {
    private var contextCirclePanel: NSPanel?
    private var contextEditorPanel: NSPanel?
    private var placementTimer: Timer?
    private var clickOutsideMonitor: Any?

    private let companionManager: CompanionManager
    private let circleSize: CGFloat = 58
    private let circleCanvasSize: CGFloat = 90
    private let contextEditorPanelWidth: CGFloat = 300
    private let contextEditorPanelHeight: CGFloat = 270
    private let screenEdgePadding: CGFloat = 24
    private let gapBetweenCircleAndEditor: CGFloat = 12

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
    }

    deinit {
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
        }
    }

    func start() {
        stop()
        placementTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateContextCircleVisibilityAndPosition()
            }
        }
        updateContextCircleVisibilityAndPosition()
    }

    func stop() {
        placementTimer?.invalidate()
        placementTimer = nil
        hideContextEditor()
        hideContextCircle()
    }

    private func updateContextCircleVisibilityAndPosition() {
        guard shouldShowContextCircle else {
            hideContextEditor()
            hideContextCircle()
            return
        }

        if contextCirclePanel == nil {
            createContextCirclePanel()
        }

        positionContextCircleOnCursorScreen()
        if contextEditorPanel?.isVisible == true {
            positionContextEditorNearCircle()
        }
        contextCirclePanel?.orderFrontRegardless()
    }

    private var shouldShowContextCircle: Bool {
        companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted
    }

    private func createContextCirclePanel() {
        let contextCircleView = ContextCircleView(
            onContextCircleClicked: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.toggleContextEditor()
                }
            },
            onFileURLsDropped: { [weak self] fileURLs in
                Task { @MainActor [weak self] in
                    self?.companionManager.addContextFiles(from: fileURLs)
                }
            }
        )
        .frame(width: circleCanvasSize, height: circleCanvasSize)
        .background(Color.clear)

        let hostingView = NSHostingView(rootView: contextCircleView)
        hostingView.frame = NSRect(x: 0, y: 0, width: circleCanvasSize, height: circleCanvasSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = ContextCirclePanel(
            contentRect: NSRect(x: 0, y: 0, width: circleCanvasSize, height: circleCanvasSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configureFloatingPanel(panel)
        panel.contentView = hostingView

        contextCirclePanel = panel
    }

    private func createContextEditorPanel() {
        let contextEditorView = ContextEditorView(companionManager: companionManager)
            .frame(width: contextEditorPanelWidth)
            .background(Color.clear)

        let hostingView = NSHostingView(rootView: contextEditorView)
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: contextEditorPanelWidth,
            height: contextEditorPanelHeight
        )
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        let panel = ContextCirclePanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: contextEditorPanelWidth,
                height: contextEditorPanelHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configureFloatingPanel(panel)
        panel.contentView = hostingView

        contextEditorPanel = panel
    }

    private func configureFloatingPanel(_ panel: NSPanel) {
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
    }

    private func positionContextCircleOnCursorScreen() {
        guard let contextCirclePanel else { return }

        let visibleFrame = currentCursorScreenVisibleFrame()
        let panelOrigin = CGPoint(
            x: visibleFrame.maxX - circleCanvasSize - screenEdgePadding + circleCanvasInset,
            y: visibleFrame.minY + screenEdgePadding - circleCanvasInset
        )

        contextCirclePanel.setFrame(
            NSRect(origin: panelOrigin, size: CGSize(width: circleCanvasSize, height: circleCanvasSize)),
            display: true
        )
    }

    private func positionContextEditorNearCircle() {
        guard let contextCirclePanel, let contextEditorPanel else { return }

        let visibleFrame = currentCursorScreenVisibleFrame()
        let circleFrame = visibleCircleFrame(in: contextCirclePanel.frame)
        let desiredOriginX = circleFrame.maxX - contextEditorPanelWidth
        let desiredOriginY = circleFrame.maxY + gapBetweenCircleAndEditor

        let clampedOriginX = min(
            max(desiredOriginX, visibleFrame.minX + screenEdgePadding),
            visibleFrame.maxX - contextEditorPanelWidth - screenEdgePadding
        )
        let clampedOriginY = min(
            max(desiredOriginY, visibleFrame.minY + screenEdgePadding),
            visibleFrame.maxY - contextEditorPanelHeight - screenEdgePadding
        )

        contextEditorPanel.setFrame(
            NSRect(
                x: clampedOriginX,
                y: clampedOriginY,
                width: contextEditorPanelWidth,
                height: contextEditorPanelHeight
            ),
            display: true
        )
    }

    private func currentCursorScreenVisibleFrame() -> CGRect {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { screen in
            screen.frame.contains(mouseLocation)
        } ?? NSScreen.main

        return targetScreen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero
    }

    private var circleCanvasInset: CGFloat {
        (circleCanvasSize - circleSize) / 2
    }

    private func visibleCircleFrame(in canvasFrame: CGRect) -> CGRect {
        return CGRect(
            x: canvasFrame.origin.x + circleCanvasInset,
            y: canvasFrame.origin.y + circleCanvasInset,
            width: circleSize,
            height: circleSize
        )
    }

    private func toggleContextEditor() {
        if contextEditorPanel?.isVisible == true {
            hideContextEditor()
        } else {
            showContextEditor()
        }
    }

    private func showContextEditor() {
        if contextEditorPanel == nil {
            createContextEditorPanel()
        }
        positionContextEditorNearCircle()
        contextEditorPanel?.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    private func hideContextEditor() {
        contextEditorPanel?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    private func hideContextCircle() {
        contextCirclePanel?.orderOut(nil)
    }

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let clickLocation = NSEvent.mouseLocation
                if let contextCirclePanel = self.contextCirclePanel,
                   self.visibleCircleFrame(in: contextCirclePanel.frame).contains(clickLocation) {
                    return
                }
                if self.contextEditorPanel?.frame.contains(clickLocation) == true {
                    return
                }
                self.hideContextEditor()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
            self.clickOutsideMonitor = nil
        }
    }
}

private struct ContextCircleView: View {
    let onContextCircleClicked: () -> Void
    let onFileURLsDropped: ([URL]) -> Void

    @State private var isHovered = false
    @State private var isDraggingFilesOverCircle = false

    var body: some View {
        ZStack {
            Color.clear

            ZStack {
                Circle()
                    .fill(circleFill)
                    .overlay(
                        Circle()
                            .stroke(circleStroke, lineWidth: isDraggingFilesOverCircle ? 2.0 : 1.0)
                    )
                    .shadow(
                        color: DS.Colors.overlayCursorBlue.opacity(isDraggingFilesOverCircle ? 0.55 : 0.30),
                        radius: isDraggingFilesOverCircle ? 18 : 10,
                        x: 0,
                        y: 6
                    )

                Image(systemName: isDraggingFilesOverCircle ? "plus" : "paperclip")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)

                ContextCircleDropTargetView(
                    isDraggingFilesOverCircle: $isDraggingFilesOverCircle,
                    onContextCircleClicked: onContextCircleClicked,
                    onFileURLsDropped: onFileURLsDropped
                )
            }
            .frame(width: 58, height: 58)
            .contentShape(Circle())
            .scaleEffect(isDraggingFilesOverCircle ? 1.08 : (isHovered ? 1.04 : 1.0))
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .animation(.easeOut(duration: DS.Animation.fast), value: isDraggingFilesOverCircle)
            .onHover { hovering in
                isHovered = hovering
            }
        }
        .frame(width: 90, height: 90)
        .background(Color.clear)
    }

    private var circleFill: some ShapeStyle {
        LinearGradient(
            colors: [
                DS.Colors.overlayCursorBlue,
                DS.Colors.blue600
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var circleStroke: Color {
        isDraggingFilesOverCircle ? Color.white.opacity(0.85) : Color.white.opacity(0.22)
    }
}

private struct ContextEditorView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 14)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    contextActionButton(
                        title: "Add file",
                        systemImageName: "doc.badge.plus",
                        action: openContextFilePicker
                    )

                    contextActionButton(
                        title: "Copy clipboard",
                        systemImageName: "doc.on.clipboard",
                        action: {
                            companionManager.copyCurrentClipboardAsContext()
                        }
                    )
                }

                if companionManager.contextAttachments.isEmpty {
                    emptyState
                } else {
                    attachmentList
                }

                if let errorMessage = companionManager.contextAttachmentErrorMessage {
                    Text(errorMessage)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.warningText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(width: 300)
        .background(panelBackground)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "paperclip")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.accentText)

                Text("Context")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            if !companionManager.contextAttachments.isEmpty {
                Button(action: {
                    companionManager.clearContextAttachments()
                }) {
                    Text("Clear")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        Text("Drag files onto the circle, add a text file, or copy your clipboard.")
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
    }

    private var attachmentList: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(companionManager.contextAttachments) { attachment in
                    contextAttachmentRow(for: attachment)
                }
            }
        }
        .frame(maxHeight: 130)
    }

    private func contextActionButton(
        title: String,
        systemImageName: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImageName)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func contextAttachmentRow(for attachment: ContextAttachment) -> some View {
        HStack(spacing: 8) {
            Image(systemName: contextAttachmentIconName(for: attachment.kind))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.accentText)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)

                Text(attachment.previewText.isEmpty ? contextAttachmentKindLabel(for: attachment.kind) : attachment.previewText)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: {
                companionManager.removeContextAttachment(id: attachment.id)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.06))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.borderSubtle.opacity(0.55), lineWidth: 0.5)
        )
    }

    private func openContextFilePicker() {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = true
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowedContentTypes = CompanionManager.supportedContextFileExtensions.compactMap { fileExtension in
            UTType(filenameExtension: fileExtension)
        }

        if openPanel.runModal() == .OK {
            companionManager.addContextFiles(from: openPanel.urls)
        }
    }

    private func contextAttachmentIconName(for kind: ContextAttachmentKind) -> String {
        switch kind {
        case .textFile:
            return "doc.text"
        case .clipboardText:
            return "doc.on.clipboard"
        case .clipboardImage:
            return "photo"
        }
    }

    private func contextAttachmentKindLabel(for kind: ContextAttachmentKind) -> String {
        switch kind {
        case .textFile:
            return "Text file"
        case .clipboardText:
            return "Clipboard text"
        case .clipboardImage:
            return "Clipboard image"
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }
}

private struct ContextCircleDropTargetView: NSViewRepresentable {
    @Binding var isDraggingFilesOverCircle: Bool
    let onContextCircleClicked: () -> Void
    let onFileURLsDropped: ([URL]) -> Void

    func makeNSView(context: Context) -> ContextCircleDropTargetNSView {
        let dropTargetView = ContextCircleDropTargetNSView()
        dropTargetView.wantsLayer = true
        dropTargetView.layer?.backgroundColor = NSColor.clear.cgColor
        dropTargetView.onDraggingStateChanged = { isDragging in
            isDraggingFilesOverCircle = isDragging
        }
        dropTargetView.onContextCircleClicked = onContextCircleClicked
        dropTargetView.onFileURLsDropped = onFileURLsDropped
        return dropTargetView
    }

    func updateNSView(_ nsView: ContextCircleDropTargetNSView, context: Context) {
        nsView.layer?.backgroundColor = NSColor.clear.cgColor
        nsView.onDraggingStateChanged = { isDragging in
            isDraggingFilesOverCircle = isDragging
        }
        nsView.onContextCircleClicked = onContextCircleClicked
        nsView.onFileURLsDropped = onFileURLsDropped
    }
}

private final class ContextCircleDropTargetNSView: NSView {
    var onDraggingStateChanged: ((Bool) -> Void)?
    var onContextCircleClicked: (() -> Void)?
    var onFileURLsDropped: (([URL]) -> Void)?

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        onContextCircleClicked?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard draggedFileURLs(from: sender).isEmpty == false else {
            return []
        }
        onDraggingStateChanged?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDraggingStateChanged?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onDraggingStateChanged?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let fileURLs = draggedFileURLs(from: sender)
        onDraggingStateChanged?(false)
        guard fileURLs.isEmpty == false else { return false }
        onFileURLsDropped?(fileURLs)
        return true
    }

    private func draggedFileURLs(from draggingInfo: NSDraggingInfo) -> [URL] {
        let pasteboard = draggingInfo.draggingPasteboard
        let fileURLReadingOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        let draggedObjects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: fileURLReadingOptions
        ) ?? []

        return draggedObjects.compactMap { draggedObject in
            if let fileURL = draggedObject as? URL {
                return fileURL
            }
            if let fileURL = draggedObject as? NSURL {
                return fileURL as URL
            }
            return nil
        }
    }
}
