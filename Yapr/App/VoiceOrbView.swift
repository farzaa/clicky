//
//  VoiceOrbView.swift
//  Yapr
//
//  The signature press-and-hold blue orb. This is the entire voice UI in v1:
//  press to start listening, release to send. State is communicated visually:
//
//    .idle       → gentle breathing pulse, soft halo
//    .listening  → reactive scale + halo intensity tied to mic power level
//    .processing → animated spinner ring while Claude thinks
//    .responding → steady glow while ElevenLabs TTS plays
//
//  The press gesture intentionally uses a zero-distance `DragGesture` rather
//  than `LongPressGesture`. `LongPressGesture` has a built-in delay before
//  it activates, which makes the orb feel laggy. `DragGesture(minimumDistance: 0)`
//  fires on touch-down with no delay, and `.onEnded` fires the moment the
//  finger lifts — exactly the "walkie-talkie" feel we want.
//

import SwiftUI

struct VoiceOrbView: View {
    let voiceState: YaprVoiceState
    let audioPowerLevel: CGFloat
    let isPressEnabled: Bool

    let onPressDown: () -> Void
    let onPressUp: () -> Void

    /// Whether the user is currently pressing the orb. Used to hold the
    /// "pressed" visual until the finger lifts, even if `voiceState`
    /// transitions to `.processing` underneath us.
    @State private var isCurrentlyPressed: Bool = false

    /// Angle for the spinner ring shown during `.processing`.
    @State private var processingSpinnerAngle: Double = 0

    /// Drives the gentle breathing animation while idle.
    @State private var idleBreathingPhase: CGFloat = 0

    var body: some View {
        ZStack {
            // Outer halo — its size and opacity grow with the orb state.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            DS.Colors.brandBlue.opacity(haloOpacity),
                            DS.Colors.brandBlue.opacity(0)
                        ],
                        center: .center,
                        startRadius: 60,
                        endRadius: 200
                    )
                )
                .frame(width: 320, height: 320)
                .scaleEffect(haloScale)
                .animation(.easeInOut(duration: 0.4), value: voiceState)
                .animation(.easeOut(duration: 0.12), value: audioPowerLevel)

            // The orb itself — gradient-filled blue circle.
            Circle()
                .fill(
                    LinearGradient(
                        colors: [DS.Colors.brandBlue, DS.Colors.brandBlueDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: orbDiameter, height: orbDiameter)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
                .shadow(color: DS.Colors.brandBlue.opacity(0.55), radius: 24, x: 0, y: 8)
                .scaleEffect(orbScale)
                .animation(.easeInOut(duration: 0.25), value: voiceState)
                .animation(.spring(response: 0.18, dampingFraction: 0.65), value: isCurrentlyPressed)
                .animation(.easeOut(duration: 0.08), value: audioPowerLevel)

            // Spinner ring — only visible during `.processing`.
            if voiceState == .processing {
                Circle()
                    .trim(from: 0, to: 0.18)
                    .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: orbDiameter + 28, height: orbDiameter + 28)
                    .rotationEffect(.degrees(processingSpinnerAngle))
                    .onAppear {
                        withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                            processingSpinnerAngle = 360
                        }
                    }
                    .onDisappear {
                        processingSpinnerAngle = 0
                    }
            }
        }
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard isPressEnabled else { return }
                    if !isCurrentlyPressed {
                        isCurrentlyPressed = true
                        onPressDown()
                    }
                }
                .onEnded { _ in
                    guard isCurrentlyPressed else { return }
                    isCurrentlyPressed = false
                    onPressUp()
                }
        )
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                idleBreathingPhase = 1
            }
        }
        .accessibilityLabel("Voice orb — press and hold to talk to Yapr.")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Visual state derivations

    private var orbDiameter: CGFloat {
        switch voiceState {
        case .idle:
            return 132
        case .listening, .processing, .responding:
            return 156
        }
    }

    private var orbScale: CGFloat {
        switch voiceState {
        case .idle:
            return 1.0 + (idleBreathingPhase * 0.04)
        case .listening:
            // Scale up with mic input level so the orb visibly reacts to
            // the user's voice. Capped at 1.18 so it never feels frantic.
            return isCurrentlyPressed
                ? 1.06 + min(audioPowerLevel * 0.18, 0.12)
                : 1.0
        case .processing:
            return 1.04
        case .responding:
            return 1.02 + (idleBreathingPhase * 0.03)
        }
    }

    private var haloScale: CGFloat {
        switch voiceState {
        case .idle:
            return 0.85 + (idleBreathingPhase * 0.05)
        case .listening:
            return 1.0 + min(audioPowerLevel * 0.4, 0.35)
        case .processing:
            return 1.05
        case .responding:
            return 1.10 + (idleBreathingPhase * 0.05)
        }
    }

    private var haloOpacity: Double {
        switch voiceState {
        case .idle:
            return 0.18
        case .listening:
            return 0.36 + min(Double(audioPowerLevel) * 0.5, 0.45)
        case .processing:
            return 0.30
        case .responding:
            return 0.42
        }
    }
}
