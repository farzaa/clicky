//
//  TextCommandPopupManager.swift
//  leanring-buddy
//
//  Manages the compact typed command popup opened by Clicky's text hotkey.
//

import AppKit
import SwiftUI

@MainActor
final class TextCommandPopupManager: NSObject {
    private final class TextCommandPanel: NSPanel {
        var onEscapeKeyPressed: (() -> Void)?

        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {
                onEscapeKeyPressed?()
                return
            }

            super.keyDown(with: event)
        }
    }

    private var panel: TextCommandPanel?
    private var popupEventMonitors: [Any] = []
    private var cursorTrackingTimer: Timer?

    private let companionManager: CompanionManager
    private let popupWidth: CGFloat = 360
    private let popupHeight: CGFloat = 62

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createPanelIfNeeded()
    }

    deinit {
        for popupEventMonitor in popupEventMonitors {
            NSEvent.removeMonitor(popupEventMonitor)
        }
    }

    func showPopup() {
        createPanelIfNeeded()
        refreshPanelContent()
        positionPopupNearCursor()

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installPopupEventMonitors()
        startTrackingCursor()
    }

    func hidePopup() {
        stopTrackingCursor()
        panel?.orderOut(nil)
        removePopupEventMonitors()
    }

    private func createPanelIfNeeded() {
        guard panel == nil else { return }

        let textCommandPanel = TextCommandPanel(
            contentRect: NSRect(x: 0, y: 0, width: popupWidth, height: popupHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        textCommandPanel.onEscapeKeyPressed = { [weak self] in
            self?.hidePopup()
        }
        textCommandPanel.isFloatingPanel = true
        textCommandPanel.level = .floating
        textCommandPanel.isOpaque = false
        textCommandPanel.backgroundColor = .clear
        textCommandPanel.hasShadow = false
        textCommandPanel.hidesOnDeactivate = false
        textCommandPanel.isExcludedFromWindowsMenu = true
        textCommandPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        textCommandPanel.isMovableByWindowBackground = false
        textCommandPanel.titleVisibility = .hidden
        textCommandPanel.titlebarAppearsTransparent = true

        panel = textCommandPanel
        refreshPanelContent()
    }

    private func refreshPanelContent() {
        let textCommandPopupView = TextCommandPopupView(companionManager: companionManager)
            .frame(width: popupWidth)

        let hostingView = NSHostingView(rootView: textCommandPopupView)
        hostingView.frame = NSRect(x: 0, y: 0, width: popupWidth, height: popupHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        panel?.contentView = hostingView
    }

    private func positionPopupNearCursor() {
        guard let panel else { return }

        let cursorLocation = NSEvent.mouseLocation
        let screenContainingCursor = NSScreen.screens.first { screen in
            screen.frame.contains(cursorLocation)
        } ?? NSScreen.main

        guard let targetScreenFrame = screenContainingCursor?.visibleFrame else { return }

        let preferredOffset = CGPoint(x: 22, y: -18)
        let preferredOrigin = CGPoint(
            x: cursorLocation.x + preferredOffset.x,
            y: cursorLocation.y - popupHeight + preferredOffset.y
        )

        let clampedOrigin = CGPoint(
            x: min(max(preferredOrigin.x, targetScreenFrame.minX + 10), targetScreenFrame.maxX - popupWidth - 10),
            y: min(max(preferredOrigin.y, targetScreenFrame.minY + 10), targetScreenFrame.maxY - popupHeight - 10)
        )

        panel.setFrame(
            NSRect(x: clampedOrigin.x, y: clampedOrigin.y, width: popupWidth, height: popupHeight),
            display: true
        )
    }

    private func startTrackingCursor() {
        stopTrackingCursor()

        cursorTrackingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.panel?.isVisible == true else { return }
                self.positionPopupNearCursor()
            }
        }
    }

    private func stopTrackingCursor() {
        cursorTrackingTimer?.invalidate()
        cursorTrackingTimer = nil
    }

    private func installPopupEventMonitors() {
        removePopupEventMonitors()

        if let localEscapeKeyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown]
        ) { [weak self] event in
            if event.keyCode == 53 {
                self?.hidePopup()
                return nil
            }

            return event
        } {
            popupEventMonitors.append(localEscapeKeyMonitor)
        }

        if let globalClickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.hidePopupIfNeeded(forClickAt: NSEvent.mouseLocation)
        } {
            popupEventMonitors.append(globalClickOutsideMonitor)
        }

        if let localClickOutsideMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.hidePopupIfNeeded(forClickAt: NSEvent.mouseLocation)
            return event
        } {
            popupEventMonitors.append(localClickOutsideMonitor)
        }
    }

    private func hidePopupIfNeeded(forClickAt clickLocation: CGPoint) {
        guard let panel else { return }
        guard !panel.frame.contains(clickLocation) else { return }

        DispatchQueue.main.async {
            self.hidePopup()
        }
    }

    private func removePopupEventMonitors() {
        for popupEventMonitor in popupEventMonitors {
            NSEvent.removeMonitor(popupEventMonitor)
        }
        popupEventMonitors.removeAll()
    }
}

private struct TextCommandPopupView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var typedCommandText = ""

    private var trimmedTypedCommandText: String {
        typedCommandText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmitTypedCommand: Bool {
        !trimmedTypedCommandText.isEmpty && !companionManager.isTextCommandSubmissionBusy
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: companionManager.isTextCommandSubmissionBusy ? "hourglass" : "bubble.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(DS.Colors.blue300)
                .frame(width: 18)

            PopupTextField(
                text: $typedCommandText,
                placeholder: companionManager.isTextCommandSubmissionBusy ? "Clicky is busy..." : "Ask Clicky...",
                isEnabled: !companionManager.isTextCommandSubmissionBusy,
                onSubmit: {
                    submitTypedCommandIfPossible()
                }
            )
            .frame(height: 22)
            .overlay(IBeamCursorView())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(DS.Colors.background.opacity(0.94))
                .shadow(color: Color.black.opacity(0.48), radius: 18, x: 0, y: 9)
                .shadow(color: DS.Colors.blue500.opacity(0.10), radius: 12, x: 0, y: 0)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.22),
                            DS.Colors.blue400.opacity(0.18),
                            Color.white.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
        )
        .padding(5)
        .onAppear {
            typedCommandText = ""
        }
    }

    private func submitTypedCommandIfPossible() {
        guard canSubmitTypedCommand else { return }
        companionManager.submitTypedCommand(trimmedTypedCommandText)
    }
}

private struct PopupTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isEnabled: Bool
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.delegate = context.coordinator
        textField.target = context.coordinator
        textField.action = #selector(Coordinator.submitTextField)
        textField.isBezeled = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.backgroundColor = .clear
        textField.focusRingType = .none
        textField.lineBreakMode = .byTruncatingTail
        textField.usesSingleLineMode = true
        textField.cell?.wraps = false
        textField.cell?.isScrollable = true
        textField.font = .systemFont(ofSize: 15, weight: .medium)
        textField.textColor = NSColor(calibratedRed: 0.925, green: 0.933, blue: 0.929, alpha: 1.0)

        DispatchQueue.main.async {
            textField.window?.makeFirstResponder(textField)
        }

        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onSubmit = onSubmit

        if textField.stringValue != text {
            textField.stringValue = text
        }

        textField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor(calibratedRed: 0.671, green: 0.710, blue: 0.698, alpha: 1.0),
                .font: NSFont.systemFont(ofSize: 15, weight: .medium)
            ]
        )
        textField.isEnabled = isEnabled

        if isEnabled && textField.window?.firstResponder !== textField.currentEditor() {
            DispatchQueue.main.async {
                textField.window?.makeFirstResponder(textField)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: () -> Void

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            text.wrappedValue = textField.stringValue
        }

        @objc func submitTextField() {
            onSubmit()
        }
    }
}
