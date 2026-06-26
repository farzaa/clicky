//
//  GuideClickTargetView.swift
//  leanring-buddy
//
//  Visual target marker for Spider's mission-aligned click guidance.
//

import Foundation
import SwiftUI

struct GuideClickTargetView: View {
    let label: String
    let missionAlignment: String

    private let clickDotSize: CGFloat = 9
    private let targetSize: CGFloat = 28

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 48.0)) { timelineContext in
            let pulse = pulseLevel(for: timelineContext.date)

            ZStack {
                Circle()
                    .stroke(DS.Colors.overlayPointer.opacity(0.20 - Double(pulse) * 0.08), lineWidth: 1.6)
                    .frame(
                        width: targetSize + pulse * 18,
                        height: targetSize + pulse * 18
                    )

                Circle()
                    .fill(DS.Colors.overlayPointer.opacity(0.12))
                    .frame(width: targetSize, height: targetSize)

                Circle()
                    .fill(Color.black.opacity(0.46))
                    .frame(width: clickDotSize + 7, height: clickDotSize + 7)

                Circle()
                    .fill(DS.Colors.overlayPointer)
                    .frame(width: clickDotSize, height: clickDotSize)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.88), lineWidth: 1.2)
                    )
                    .shadow(color: DS.Colors.overlayPointer.opacity(0.78), radius: 7, x: 0, y: 0)
            }
            .frame(width: targetSize + 24, height: targetSize + 24)
            .compositingGroup()
            .accessibilityLabel(Text(accessibilityText))
        }
    }

    private var accessibilityText: String {
        let parts = [label, missionAlignment]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? "Guide target" : parts.joined(separator: ". ")
    }

    private func pulseLevel(for date: Date) -> CGFloat {
        let rawPhase = sin(date.timeIntervalSinceReferenceDate * 5.2)
        return CGFloat((rawPhase + 1.0) / 2.0)
    }
}

#if DEBUG
#Preview("Mission pointer target") {
    ZStack {
        Color.black.opacity(0.92)
        GuideClickTargetView(
            label: "Leads",
            missionAlignment: "Matches selected mission"
        )
    }
    .frame(width: 320, height: 220)
}
#endif
