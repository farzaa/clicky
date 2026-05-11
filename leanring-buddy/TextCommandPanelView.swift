//
//  TextCommandPanelView.swift
//  leanring-buddy
//
//  Floating single-line command palette for typing commands to Dot.
//  Same downstream pipeline as a push-to-talk voice transcript — the
//  submitted text is fed straight into the agent loop. The panel is
//  triggered by cmd+shift+space (see GlobalPushToTalkShortcutMonitor's
//  `textCommandToggleRequestPublisher`) and auto-dismisses on submit
//  or escape so screenshots aren't obstructed.
//

import SwiftUI

struct TextCommandPanelView: View {
    /// Called when the user submits a non-empty command. The panel hides
    /// before this fires (managed by TextCommandPanelManager) so the
    /// agent loop's first screenshot doesn't include the panel itself.
    let onSubmitCommand: (String) -> Void

    /// Called when the user presses escape or the view otherwise wants
    /// to dismiss (e.g., after a successful submit so the manager can
    /// hide the panel and restore focus to the previous app).
    let onDismiss: () -> Void

    @State private var commandInputText: String = ""
    @FocusState private var isCommandFieldFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Tiny status dot on the left so the panel reads as a Dot
            // surface, not a generic command palette.
            Circle()
                .fill(DS.Colors.overlayCursorBlue)
                .frame(width: 10, height: 10)
                .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.6), radius: 6, x: 0, y: 0)

            TextField("type a command for dot...", text: $commandInputText)
                .textFieldStyle(.plain)
                .focused($isCommandFieldFocused)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(.white)
                .onSubmit {
                    submitCurrentCommand()
                }

            Button(action: submitCurrentCommand) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(commandInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                     ? Color.white.opacity(0.25)
                                     : Color.white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .disabled(commandInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("send command (return)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 10)
        )
        .onAppear {
            // Defer focus to the next runloop tick so the panel has
            // become key by the time we ask SwiftUI to grab focus.
            DispatchQueue.main.async {
                isCommandFieldFocused = true
            }
        }
    }

    private func submitCurrentCommand() {
        let trimmedCommand = commandInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return }
        // Clear the field BEFORE invoking the submit handler — the
        // handler hides the panel and we don't want a stale value
        // visible if the user reopens it before the next render.
        commandInputText = ""
        onSubmitCommand(trimmedCommand)
    }
}
