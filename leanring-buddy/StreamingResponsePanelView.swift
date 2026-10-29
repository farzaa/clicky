//
//  StreamingResponsePanelView.swift
//  leanring-buddy
//
//  The floating chat panel that hosts the conversation between the user
//  and Clicky during text-mode chat. Renders as a compact, polished
//  message thread with:
//    - Right-aligned blue bubbles for the user's prompts
//    - Left-aligned flat text for Claude's responses (cleaner reading)
//    - An animated "thinking dots" indicator while the AI is processing
//    - A bottom input row for sending follow-up messages
//    - A small X button in the top-right to dismiss the chat
//
//  Designed to feel like a native macOS chat app — soft shadows, hairline
//  borders, generous spacing, subtle animations on new content.
//

import SwiftUI

struct StreamingResponsePanelView: View {
    /// Completed turns of the chat. Rendered top-to-bottom.
    let conversationHistory: [CompanionConversationTurn]
    /// The user's most recent prompt that's currently being processed.
    /// Rendered as the latest user bubble below the completed history,
    /// followed by either the streaming response or a thinking indicator.
    let pendingUserPrompt: String?
    /// Streamed assistant text for the in-flight turn. Empty during the
    /// processing window before the first chunk arrives.
    let streamingResponseText: String
    /// True while the in-flight turn hasn't finished — drives whether
    /// the bottom indicator shows the thinking dots or the streamed text.
    let isProcessingCurrentTurn: Bool
    /// Called when the user sends a follow-up via the input row.
    let onSubmitFollowUp: (String) -> Void
    /// Called when the user clicks the X close button.
    let onDismiss: () -> Void

    /// Local input state for the bottom text field. Cleared on submit.
    @State private var followUpText: String = ""
    /// Drives the auto-focus behavior so the input field is ready
    /// immediately when the panel appears.
    @FocusState private var isInputFieldFocused: Bool

    /// Fixed panel width — wide enough to read multi-line responses
    /// comfortably without dominating the screen.
    static let panelWidth: CGFloat = 440

    /// Vertical scroll target ID — placed at the very bottom of the
    /// thread and used by `ScrollViewReader` to keep the latest content
    /// in view as new chunks stream in.
    private static let scrollAnchorBottomID = "chat.bottom"

    var body: some View {
        VStack(spacing: 0) {
            chatThread
            inputBar
        }
        .frame(width: Self.panelWidth)
        .frame(minHeight: 88)
        .background(panelBackground)
        .overlay(panelBorder)
        .overlay(closeButton, alignment: .topTrailing)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 12)
    }

    // MARK: - Chat Thread

    private var chatThread: some View {
        ScrollViewReader { scrollProxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    // Completed turns
                    ForEach(conversationHistory) { turn in
                        ChatTurnView(
                            userMessage: turn.userMessage,
                            assistantResponse: turn.assistantResponse,
                            isAssistantStreaming: false,
                            isAssistantThinking: false
                        )
                        .id(turn.id)
                        .onAppear {
                            print("📌 ChatTurnView appeared (history): user=\(turn.userMessage.prefix(20)), assistant.count=\(turn.assistantResponse.count)")
                        }
                    }

                    // In-flight turn — the user's pending prompt + either
                    // the streaming response so far, or the thinking dots
                    // if no chunks have arrived yet.
                    if let pendingPrompt = pendingUserPrompt {
                        ChatTurnView(
                            userMessage: pendingPrompt,
                            assistantResponse: streamingResponseText,
                            isAssistantStreaming: isProcessingCurrentTurn && !streamingResponseText.isEmpty,
                            isAssistantThinking: isProcessingCurrentTurn && streamingResponseText.isEmpty
                        )
                        .id("inflight")
                        .onAppear {
                            print("📌 ChatTurnView appeared (in-flight): pending=\(pendingPrompt.prefix(20)), streaming.count=\(streamingResponseText.count)")
                        }
                    }

                    // Anchor for auto-scroll
                    Color.clear
                        .frame(height: 1)
                        .id(Self.scrollAnchorBottomID)
                }
                .padding(.horizontal, 22)
                .padding(.top, 38)
                .padding(.bottom, 14)
            }
            .frame(maxHeight: 460)
            // Auto-scroll to the latest content as the chat grows.
            // Watching `streamingResponseText` keeps the view pinned to
            // the bottom while text streams in chunk-by-chunk.
            .onChange(of: streamingResponseText) { _ in
                scrollToBottom(scrollProxy)
            }
            .onChange(of: pendingUserPrompt) { _ in
                scrollToBottom(scrollProxy)
            }
            .onChange(of: conversationHistory.count) { _ in
                scrollToBottom(scrollProxy)
            }
            .onAppear {
                scrollToBottom(scrollProxy, animated: false)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.22)) {
                proxy.scrollTo(Self.scrollAnchorBottomID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(Self.scrollAnchorBottomID, anchor: .bottom)
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            // Hairline divider between the chat thread and the input.
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 0.5)

            HStack(spacing: 10) {
                TextField("Ask a follow-up", text: $followUpText)
                    .textFieldStyle(.plain)
                    .focused($isInputFieldFocused)
                    .font(.system(size: 13))
                    .foregroundColor(.white)
                    .tint(DS.Colors.overlayCursorBlue)
                    .onSubmit {
                        submitFollowUpIfNonEmpty()
                    }

                sendButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 14)
            .onAppear {
                // Auto-focus a beat after appear so the panel has fully
                // become key — without the small delay the focus is
                // sometimes stolen back as the panel finishes ordering in.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isInputFieldFocused = true
                }
            }
        }
    }

    private var sendButton: some View {
        let trimmed = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSubmit = !trimmed.isEmpty
        return Button(action: submitFollowUpIfNonEmpty) {
            Image(systemName: "arrow.up")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(canSubmit ? DS.Colors.overlayCursorBlue : Color.white.opacity(0.10))
                )
                .scaleEffect(canSubmit ? 1.0 : 0.94)
                .animation(.easeOut(duration: 0.15), value: canSubmit)
        }
        .buttonStyle(.plain)
        .pointerCursor(isEnabled: canSubmit)
        .disabled(!canSubmit)
    }

    private func submitFollowUpIfNonEmpty() {
        let trimmed = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmitFollowUp(trimmed)
        followUpText = ""
    }

    // MARK: - Decoration

    private var panelBackground: some View {
        // Slightly elevated dark with a faint top-down gradient gives the
        // panel depth without being noisy. Pure flat #101211 looks fine
        // but the gradient adds a touch of polish at no cost.
        LinearGradient(
            colors: [
                Color(red: 0.08, green: 0.09, blue: 0.10),
                Color(red: 0.06, green: 0.07, blue: 0.07)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var panelBorder: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(0.65))
                .frame(width: 20, height: 20)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .padding(.top, 10)
        .padding(.trailing, 10)
    }
}

// MARK: - Per-Turn View

/// Renders one user → assistant exchange. The user message is a
/// right-aligned blue bubble (matching the cursor color and the floating
/// input bubble's color so the conversation feels visually unified). The
/// assistant response is left-aligned flat text — cleaner to read for
/// longer responses, and avoids a "two-bubbles-stacked" look that feels
/// busy in a compact panel.
private struct ChatTurnView: View {
    let userMessage: String
    let assistantResponse: String
    /// True while the assistant text is mid-stream — drives a subtle
    /// trailing caret to signal "more is coming."
    let isAssistantStreaming: Bool
    /// True while we're still waiting for the very first response chunk.
    /// Replaces the assistant text with an animated thinking indicator.
    let isAssistantThinking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            userBubble
            assistantContent
        }
    }

    private var userBubble: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 48)
            Text(userMessage)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(DS.Colors.overlayCursorBlue)
                )
        }
    }

    @ViewBuilder
    private var assistantContent: some View {
        if isAssistantThinking {
            HStack(spacing: 0) {
                ThinkingDots()
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                Spacer(minLength: 0)
            }
            .transition(.opacity)
        } else {
            HStack(spacing: 0) {
                AssistantTextWithCursor(
                    text: assistantResponse,
                    showStreamingCursor: isAssistantStreaming
                )
                Spacer(minLength: 32)
            }
        }
    }
}

/// The assistant's response text, optionally with a trailing blinking
/// caret while text is still streaming. The caret is a subtle visual
/// signal that the response isn't done yet — like the typing indicator
/// in chat apps but inline at the end of the text.
private struct AssistantTextWithCursor: View {
    let text: String
    let showStreamingCursor: Bool

    @State private var isCursorVisible = true

    var body: some View {
        Group {
            if showStreamingCursor {
                // Use Text concatenation so the caret hugs the last
                // character on the line — no awkward HStack wrapping when
                // text spans multiple lines.
                (Text(text)
                    + Text(isCursorVisible ? "▌" : " ")
                        .foregroundColor(DS.Colors.overlayCursorBlue))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.white.opacity(0.95))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.5).repeatForever()) {
                            isCursorVisible.toggle()
                        }
                    }
            } else {
                Text(text)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.white.opacity(0.95))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Three small dots that pulse in sequence — the "AI is thinking"
/// indicator shown while waiting for the first response chunk. Sized
/// and timed to match the visual language of macOS native typing
/// indicators rather than the heavier voice-mode spinner.
private struct ThinkingDots: View {
    @State private var animationPhase: Int = 0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { dotIndex in
                Circle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: 6, height: 6)
                    .scaleEffect(scaleForDot(at: dotIndex))
                    .opacity(opacityForDot(at: dotIndex))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                animationPhase = 1
            }
        }
    }

    private func scaleForDot(at index: Int) -> CGFloat {
        // Each dot peaks at a different phase so they pulse in sequence.
        let phaseOffset = Double(index) * 0.2
        let pulse = sin((Double(animationPhase) + phaseOffset) * .pi)
        return 0.7 + CGFloat(pulse) * 0.3
    }

    private func opacityForDot(at index: Int) -> Double {
        let phaseOffset = Double(index) * 0.2
        let pulse = sin((Double(animationPhase) + phaseOffset) * .pi)
        return 0.4 + pulse * 0.6
    }
}
