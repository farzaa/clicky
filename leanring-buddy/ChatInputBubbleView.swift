//
//  ChatInputBubbleView.swift
//  leanring-buddy
//
//  Floating chat bubble that appears next to the AI cursor when the user
//  presses the push-to-talk hotkey while Clicky is in `.text` input mode.
//  Visually styled to look like a speech bubble emerging from the cursor:
//  a true capsule (corner radius = height/2) in the same blue as the
//  cursor (DS.Colors.overlayCursorBlue), with a small triangular tail on
//  the upper-left edge pointing back toward the cursor.
//
//  Submission lifecycle:
//    - Pressing return submits the trimmed text to `onSubmit` and dismisses.
//    - Pressing escape (or clicking outside, handled by ChatInputBubbleManager)
//      dismisses without submitting via `onCancel`.
//    - The text field auto-focuses on appear so the user can start typing
//      immediately without having to click the bubble first.
//

import SwiftUI

/// Speech-bubble shape: a capsule body (corner radius = body height / 2) with
/// a small triangular tail on the upper-left edge, pointing toward the AI
/// cursor (which sits to the upper-left of the bubble in the layout used
/// by ChatInputBubbleManager).
struct ChatBubbleShape: Shape {
    /// Where on the bubble's left edge the tail should attach (0 = top, 1 = bottom).
    /// 0.25 puts the tail near the upper-left to match the Figma reference,
    /// where the tail emerges from the bubble pointing up-and-left toward
    /// the cursor.
    var tailVerticalAnchor: CGFloat = 0.28
    /// How far the tail sticks out from the bubble's left edge, in points.
    var tailWidth: CGFloat = 9
    /// Vertical extent of the tail, in points. Slightly larger than the
    /// width gives the tail a leaning-upward shape rather than a point.
    var tailHeight: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        var path = Path()

        // Bubble body — capsule. Corner radius is exactly half the body's
        // height so the left and right edges round all the way around.
        // Inset from the left to leave room for the tail to extrude beyond
        // the body's left edge.
        let bodyRect = CGRect(
            x: rect.minX + tailWidth,
            y: rect.minY,
            width: rect.width - tailWidth,
            height: rect.height
        )
        let capsuleCornerRadius = bodyRect.height / 2.0
        path.addRoundedRect(
            in: bodyRect,
            cornerSize: CGSize(width: capsuleCornerRadius, height: capsuleCornerRadius),
            style: .continuous
        )

        // Tail — small triangle sticking out from the left edge of the
        // body, pointing up-and-left toward where the cursor sits.
        let tailCenterY = rect.minY + (rect.height * tailVerticalAnchor)
        let tailTipX = rect.minX
        let tailTipY = tailCenterY - (tailHeight * 0.45)
        let tailTopAnchor = CGPoint(x: bodyRect.minX, y: tailCenterY - (tailHeight / 2))
        let tailBottomAnchor = CGPoint(x: bodyRect.minX, y: tailCenterY + (tailHeight / 2))

        path.move(to: tailTopAnchor)
        path.addLine(to: CGPoint(x: tailTipX, y: tailTipY))
        path.addLine(to: tailBottomAnchor)
        path.closeSubpath()

        return path
    }
}

struct ChatInputBubbleView: View {
    /// Called when the user presses return with non-empty trimmed text.
    let onSubmit: (String) -> Void
    /// Called when the user presses escape to dismiss without submitting.
    let onCancel: () -> Void

    @State private var typedText: String = ""
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            TextField("Say something", text: $typedText)
                .textFieldStyle(.plain)
                .focused($isTextFieldFocused)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .tint(.white)
                .onSubmit {
                    submitIfNonEmpty()
                }
        }
        // Extra padding on the leading edge so text sits clear of the tail.
        .padding(.leading, 24)
        .padding(.trailing, 22)
        .padding(.vertical, 11)
        .background(
            ChatBubbleShape()
                .fill(DS.Colors.overlayCursorBlue)
        )
        .onAppear {
            // Slight delay lets the hosting NSPanel finish becoming key
            // before we request focus — without this the field can lose
            // its first-responder status as the panel finishes ordering in.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isTextFieldFocused = true
            }
        }
    }

    private func submitIfNonEmpty() {
        let trimmed = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }
}
