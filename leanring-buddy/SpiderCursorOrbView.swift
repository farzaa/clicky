//
//  SpiderCursorOrbView.swift
//  leanring-buddy
//
//  Animated idle/responding cursor orb for the Spider overlay.
//

import SwiftUI

struct SpiderCursorOrbView: View {
    let isSpeaking: Bool

    private let size: CGFloat = 18

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 48.0)) { timelineContext in
            let phase = normalizedPulse(for: timelineContext.date)
            let speechLevel = isSpeaking ? speechEnvelope(for: timelineContext.date) : 0
            let pulseScale = isSpeaking ? 0.98 + speechLevel * 0.16 : 0.94 + phase * 0.10

            ZStack {
                if isSpeaking {
                    ForEach(0..<2, id: \.self) { ringIndex in
                        Circle()
                            .stroke(
                                DS.Colors.overlayPointer.opacity(speechRingOpacity(for: ringIndex, speechLevel: speechLevel)),
                                lineWidth: 1.05
                            )
                            .frame(
                                width: speechRingDiameter(for: ringIndex, speechLevel: speechLevel),
                                height: speechRingDiameter(for: ringIndex, speechLevel: speechLevel)
                            )
                    }
                }

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(0.54),
                                DS.Colors.overlayPointer,
                                DS.Colors.overlayPointer.opacity(0.78),
                            ],
                            center: .topLeading,
                            startRadius: 1,
                            endRadius: size * 0.72
                        )
                    )
                    .frame(width: size, height: size)

                Circle()
                    .stroke(Color.white.opacity(0.34 + phase * 0.12), lineWidth: 1.1)
                    .frame(width: size, height: size)

                Circle()
                    .fill(Color.white.opacity(0.46))
                    .frame(width: 4.4, height: 4.4)
                    .offset(x: -3.6, y: -4.2)

                if isSpeaking {
                    HStack(alignment: .center, spacing: 1.6) {
                        ForEach(0..<3, id: \.self) { barIndex in
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.76))
                                .frame(
                                    width: 1.45,
                                    height: speechBarHeight(for: barIndex, date: timelineContext.date)
                                )
                        }
                    }
                    .offset(y: 1.2)
                }
            }
            .frame(width: size, height: size)
            .scaleEffect(pulseScale)
        }
    }

    private func normalizedPulse(for date: Date) -> CGFloat {
        let rawPhase = sin(date.timeIntervalSinceReferenceDate * 3.2)
        return CGFloat((rawPhase + 1.0) / 2.0)
    }

    private func speechEnvelope(for date: Date) -> CGFloat {
        let time = date.timeIntervalSinceReferenceDate
        let fast = (sin(time * 18.0) + 1.0) / 2.0
        let mid = (sin(time * 10.4 + 1.7) + 1.0) / 2.0
        let slow = (sin(time * 4.7 + 0.4) + 1.0) / 2.0
        return CGFloat(min(max(fast * 0.44 + mid * 0.38 + slow * 0.18, 0), 1))
    }

    private func speechRingDiameter(for ringIndex: Int, speechLevel: CGFloat) -> CGFloat {
        size + 5 + CGFloat(ringIndex) * 5 + speechLevel * (4 + CGFloat(ringIndex) * 3)
    }

    private func speechRingOpacity(for ringIndex: Int, speechLevel: CGFloat) -> Double {
        let baseOpacity = 0.30 - Double(ringIndex) * 0.10
        return baseOpacity + Double(speechLevel) * 0.22
    }

    private func speechBarHeight(for barIndex: Int, date: Date) -> CGFloat {
        let time = date.timeIntervalSinceReferenceDate
        let offset = Double(barIndex) * 0.92
        let level = (sin(time * 16.0 + offset) + 1.0) / 2.0
        let secondary = (sin(time * 9.0 + offset * 1.7) + 1.0) / 2.0
        let mixedLevel = CGFloat(level * 0.68 + secondary * 0.32)
        return 3.2 + mixedLevel * 6.2
    }
}
