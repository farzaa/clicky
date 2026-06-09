//
//  ResponseBubbleView.swift
//  Yapr
//
//  Compact text bubble shown above the voice orb during `.responding`,
//  displaying the spoken response text alongside the audio playback.
//  This mirrors the macOS app's `CompanionResponseOverlay` but is
//  inline in the iOS layout instead of a free-floating overlay.
//

import SwiftUI

struct ResponseBubbleView: View {
    let voiceState: YaprVoiceState
    let lastTranscript: String?
    let responseText: String
    let lastErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let lastErrorMessage {
                errorBubble(text: lastErrorMessage)
            } else if voiceState == .processing {
                statusBubble(text: "thinking…")
            } else if voiceState == .responding && !responseText.isEmpty {
                responseBubble(text: responseText)
            } else if voiceState == .listening {
                statusBubble(text: "listening…")
            } else if let lastTranscript, !lastTranscript.isEmpty {
                statusBubble(text: "you: \(lastTranscript)")
            } else {
                hintBubble
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.18), value: voiceState)
        .animation(.easeInOut(duration: 0.18), value: responseText)
    }

    private func responseBubble(text: String) -> some View {
        Text(text)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(DS.Colors.textPrimary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .fill(DS.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 1)
            )
    }

    private func statusBubble(text: String) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(DS.Colors.brandBlue)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(DS.Colors.textSecondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule().fill(DS.Colors.surface)
        )
        .overlay(
            Capsule().stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    private func errorBubble(text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(DS.Colors.warning)
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule().fill(DS.Colors.surface)
        )
        .overlay(
            Capsule().stroke(DS.Colors.warning.opacity(0.4), lineWidth: 1)
        )
    }

    private var hintBubble: some View {
        Text("hold the orb, ask anything about your screenshot.")
            .font(.system(size: 14))
            .foregroundStyle(DS.Colors.textTertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }
}
