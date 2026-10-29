//
//  TextPromptWindowManager.swift
//  leanring-buddy
//
//  A small floating prompt for sending typed messages through the same
//  screenshot -> AI -> speech/pointing pipeline as push-to-talk.
//

import AppKit
import SwiftUI

private final class TextPromptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

@MainActor
final class TextPromptWindowManager {
    private var panel: NSPanel?

    func show(companionManager: CompanionManager) {
        if panel == nil {
            createPanel(companionManager: companionManager)
        }

        if panel?.isVisible != true {
            positionPanelNearCursor()
        }
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func createPanel(companionManager: CompanionManager) {
        let promptPanel = TextPromptPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 250),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        let promptView = TextPromptPanelView(
            companionManager: companionManager,
            onClose: { [weak self] in
                Task { @MainActor in
                    self?.hide()
                }
            }
        )
        .frame(width: 520, height: 250)

        let hostingView = NSHostingView(rootView: promptView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 520, height: 250)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        promptPanel.isFloatingPanel = true
        promptPanel.level = .floating
        promptPanel.isOpaque = false
        promptPanel.backgroundColor = .clear
        promptPanel.hasShadow = true
        promptPanel.hidesOnDeactivate = false
        promptPanel.isExcludedFromWindowsMenu = true
        promptPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        promptPanel.isMovableByWindowBackground = true
        promptPanel.titleVisibility = .hidden
        promptPanel.titlebarAppearsTransparent = true
        promptPanel.contentView = hostingView

        panel = promptPanel
    }

    private func positionPanelNearCursor() {
        guard let panel else { return }

        let panelSize = panel.frame.size
        let cursorLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { screen in
            screen.frame.contains(cursorLocation)
        } ?? NSScreen.main

        guard let targetScreen else { return }

        let visibleFrame = targetScreen.visibleFrame
        let proposedOriginX = cursorLocation.x - (panelSize.width / 2)
        let proposedOriginY = cursorLocation.y - panelSize.height - 24
        let clampedOriginX = min(
            max(proposedOriginX, visibleFrame.minX + 16),
            visibleFrame.maxX - panelSize.width - 16
        )
        let clampedOriginY = min(
            max(proposedOriginY, visibleFrame.minY + 16),
            visibleFrame.maxY - panelSize.height - 16
        )

        panel.setFrame(
            NSRect(
                x: clampedOriginX,
                y: clampedOriginY,
                width: panelSize.width,
                height: panelSize.height
            ),
            display: true
        )
    }
}

private struct TextPromptPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    let onClose: () -> Void

    @State private var promptText = ""
    @FocusState private var isPromptFocused: Bool

    private var trimmedPromptText: String {
        promptText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            promptEditor
            footer
        }
        .padding(16)
        .background(panelBackground)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isPromptFocused = true
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.accentText)

            VStack(alignment: .leading, spacing: 2) {
                Text("Ask Clicky")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text("Type a message. Clicky will still look at your screen.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    private var promptEditor: some View {
        TextEditor(text: $promptText)
            .font(.system(size: 13))
            .foregroundColor(DS.Colors.textPrimary)
            .scrollContentBackground(.hidden)
            .background(DS.Colors.surface2)
            .focused($isPromptFocused)
            .frame(height: 118)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
    }

    private var footer: some View {
        HStack {
            Text("Command+Return sends")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Spacer()

            Button(action: submitPrompt) {
                Text("Send")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(trimmedPromptText.isEmpty ? DS.Colors.surface4 : DS.Colors.accent)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(trimmedPromptText.isEmpty)
            .pointerCursor(isEnabled: !trimmedPromptText.isEmpty)
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(DS.Colors.surface1)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
    }

    private func submitPrompt() {
        let textToSubmit = trimmedPromptText
        guard !textToSubmit.isEmpty else { return }

        companionManager.submitTypedMessage(textToSubmit)
        promptText = ""
        isPromptFocused = true
    }
}
