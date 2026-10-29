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

/// Speech-bubble shape: a capsule body (corner radius = body height / 2)
/// with a small triangular tail on the upper-left edge.
///
/// Why the tip's y is intentionally aligned with the top body-anchor's y
/// (creating a horizontal upper edge): if the tip sat ABOVE the top
/// body-anchor, the tail's diagonal upper edge would slant up-and-left
/// from the body's curve to the tip. But above the body-anchor's y, the
/// capsule's outline curves outward (rightward) — so between the tail's
/// upper edge and the capsule's curve there's a wedge of empty space
/// that reads as a gap detaching the tail from the bubble.
///
/// Aligning the tip with the top anchor's y makes the upper edge purely
/// horizontal, eliminating that wedge entirely. The tail then reads as a
/// small flag/pennant emerging from the bubble's upper-left, with all
/// edges either resting on the bubble's curve or extending cleanly out
/// to the tip.
struct ChatBubbleShape: Shape {
    /// Where on the bubble's vertical axis the tail's TOP edge attaches
    /// (0 = bubble top, 1 = bubble bottom). 0.18 puts the tail's top
    /// fairly high on the bubble, with the tail extending downward and
    /// outward from there.
    var tailVerticalAnchor: CGFloat = 0.18
    /// How far the tail's tip sticks out from the bubble's left edge.
    var tailWidth: CGFloat = 11
    /// Vertical extent of the tail (from top edge to the bottom anchor).
    var tailHeight: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        var path = Path()

        // Bubble body — capsule. Corner radius is exactly half the body's
        // height so the left and right edges round all the way around.
        // Inset from the left to leave room for the tail to extrude.
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

        // Tail — flag/pennant shape. The tip and the top body-anchor share
        // the same y so the upper edge is horizontal (no wedge of empty
        // space above the tip). The bottom body-anchor is below them on
        // the curve, with the tip-to-bottom edge slanting down-right.
        let tailTopY = bodyRect.minY + (bodyRect.height * tailVerticalAnchor)
        let tailBottomY = tailTopY + tailHeight
        let tailTipX = rect.minX
        let tailTipY = tailTopY

        let topAnchorX = leftEdgeX(at: tailTopY, in: bodyRect, cornerRadius: capsuleCornerRadius)
        let bottomAnchorX = leftEdgeX(at: tailBottomY, in: bodyRect, cornerRadius: capsuleCornerRadius)

        path.move(to: CGPoint(x: tailTipX, y: tailTipY))
        path.addLine(to: CGPoint(x: topAnchorX, y: tailTopY))
        path.addLine(to: CGPoint(x: bottomAnchorX, y: tailBottomY))
        path.closeSubpath()

        return path
    }

    /// Returns the x-coordinate of the body's left outline at a given y.
    /// For a capsule (corner radius = half-height), every y on the left
    /// side is within a corner curve, so this solves the circle equation
    /// for the quarter-arc. Without this, anchoring at `bodyRect.minX`
    /// places the tail outside the actual visible curve, leaving a gap.
    private func leftEdgeX(at y: CGFloat, in bodyRect: CGRect, cornerRadius: CGFloat) -> CGFloat {
        let centerY = bodyRect.midY
        let yOffsetFromCenter = abs(y - centerY)

        // Outside the corner zone (won't happen for a true capsule but
        // covered for safety in case future tweaks reduce cornerRadius).
        if yOffsetFromCenter >= cornerRadius {
            return bodyRect.minX
        }

        // Solve circle equation: x² + (y - centerY)² = r² → x = sqrt(r² - dy²).
        // The body's left edge at this y is `cornerRadius - x` to the right
        // of `bodyRect.minX`.
        let dx = sqrt(cornerRadius * cornerRadius - yOffsetFromCenter * yOffsetFromCenter)
        return bodyRect.minX + (cornerRadius - dx)
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
