//
//  SpiderCursorVoiceStateViews.swift
//  leanring-buddy
//
//  Voice-state cursor indicators for listening and processing states.
//

import SwiftUI

struct SpiderCursorPushToTalkPulseView: View {
    let audioPowerLevel: CGFloat

    private let coreSize: CGFloat = 18

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 48.0)) { timelineContext in
            let level = normalizedAudioPowerLevel
            let breath = breathingLevel(for: timelineContext.date)
            let coreScale = 0.88 + breath * 0.10 + level * 0.24

            ZStack {
                ForEach(0..<3, id: \.self) { ringIndex in
                    Circle()
                        .stroke(
                            DS.Colors.overlayPointer.opacity(ringOpacity(for: ringIndex, breath: breath, audioLevel: level)),
                            lineWidth: ringLineWidth(for: ringIndex, audioLevel: level)
                        )
                        .frame(
                            width: ringDiameter(for: ringIndex, breath: breath, audioLevel: level),
                            height: ringDiameter(for: ringIndex, breath: breath, audioLevel: level)
                        )
                }

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(0.56),
                                DS.Colors.overlayPointer,
                                DS.Colors.overlayPointer.opacity(0.76),
                            ],
                            center: .topLeading,
                            startRadius: 1,
                            endRadius: coreSize * 0.72
                        )
                    )
                    .frame(width: coreSize, height: coreSize)
                    .scaleEffect(coreScale)

                Circle()
                    .stroke(Color.white.opacity(0.34 + Double(level) * 0.24), lineWidth: 1.1)
                    .frame(width: coreSize, height: coreSize)
                    .scaleEffect(coreScale)

                Circle()
                    .fill(Color.white.opacity(0.50))
                    .frame(width: 4.2, height: 4.2)
                    .offset(x: -3.5, y: -4.1)
                    .scaleEffect(0.95 + level * 0.18)
            }
            .frame(width: 36, height: 36)
            .shadow(color: DS.Colors.overlayPointer.opacity(0.52 + Double(level) * 0.24), radius: 8 + level * 8, x: 0, y: 0)
            .animation(.linear(duration: 0.08), value: audioPowerLevel)
        }
    }

    private var normalizedAudioPowerLevel: CGFloat {
        let normalizedLevel = max(audioPowerLevel - 0.008, 0)
        return pow(min(normalizedLevel * 3.0, 1), 0.72)
    }

    private func breathingLevel(for date: Date) -> CGFloat {
        let rawPhase = sin(date.timeIntervalSinceReferenceDate * 5.6)
        return CGFloat((rawPhase + 1.0) / 2.0)
    }

    private func ringDiameter(for ringIndex: Int, breath: CGFloat, audioLevel: CGFloat) -> CGFloat {
        coreSize + 6 + CGFloat(ringIndex) * 6 + breath * 5 + audioLevel * (7 + CGFloat(ringIndex) * 2)
    }

    private func ringOpacity(for ringIndex: Int, breath: CGFloat, audioLevel: CGFloat) -> Double {
        let baseOpacity = 0.34 - Double(ringIndex) * 0.08
        return baseOpacity + Double(breath) * 0.10 + Double(audioLevel) * 0.16
    }

    private func ringLineWidth(for ringIndex: Int, audioLevel: CGFloat) -> CGFloat {
        0.85 + CGFloat(ringIndex) * 0.1 + audioLevel * 0.35
    }
}

struct SpiderCursorSpinnerView: View {
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(
                AngularGradient(
                    colors: [
                        DS.Colors.overlayPointer.opacity(0.0),
                        DS.Colors.overlayPointer
                    ],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .shadow(color: DS.Colors.overlayPointer.opacity(0.6), radius: 6, x: 0, y: 0)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    isSpinning = true
                }
            }
    }
}
