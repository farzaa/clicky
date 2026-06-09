//
//  RootView.swift
//  Yapr
//
//  Single-screen root layout.
//
//  Layout (top → bottom):
//    • Title bar with the Yapr wordmark.
//    • Screenshot preview (or empty state) — fills remaining vertical space.
//    • Response bubble / status text.
//    • Voice orb pinned near the bottom for thumb reach.
//
//  When permissions are missing, the preview + orb are replaced with the
//  `PermissionsGateView`. This keeps the surface area tiny for v1 — there
//  is no settings screen, no history list, no model picker. Those can be
//  added later without restructuring this layout.
//

import SwiftUI

struct RootView: View {
    @StateObject private var viewModel = YaprViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            DS.Colors.background.ignoresSafeArea()

            VStack(spacing: 16) {
                titleBar

                if viewModel.hasAllRequiredPermissions {
                    activeContent
                } else {
                    PermissionsGateView(
                        microphoneStatus: viewModel.microphoneAuthorizationStatus,
                        photosStatus: viewModel.photosAuthorizationStatus,
                        onRequestMicrophonePermission: {
                            Task { await viewModel.requestMicrophonePermission() }
                        },
                        onRequestPhotosPermission: {
                            Task { await viewModel.requestPhotosPermission() }
                        }
                    )
                    .padding(.horizontal, 20)

                    Spacer(minLength: 0)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .preferredColorScheme(.dark)
        .task {
            await viewModel.bootstrap()
            await viewModel.handleControlCenterLaunchIfApplicable()
        }
        .onChange(of: scenePhase) { _, newScenePhase in
            if newScenePhase == .active {
                Task {
                    await viewModel.refreshOnForeground()
                    await viewModel.handleControlCenterLaunchIfApplicable()
                }
            }
        }
    }

    // MARK: - Sections

    private var titleBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [DS.Colors.brandBlue, DS.Colors.brandBlueDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 18, height: 18)

            Text("yapr")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(DS.Colors.textPrimary)

            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private var activeContent: some View {
        VStack(spacing: 16) {
            ScreenshotPreviewView(
                fetchedScreenshot: viewModel.currentScreenshot,
                pointingTarget: viewModel.pointingTarget
            )
            .padding(.horizontal, 20)

            ResponseBubbleView(
                voiceState: viewModel.voiceState,
                lastTranscript: viewModel.lastTranscript,
                responseText: viewModel.streamingResponseText,
                lastErrorMessage: viewModel.lastErrorMessage
            )
            .padding(.horizontal, 20)

            Spacer(minLength: 0)

            VoiceOrbView(
                voiceState: viewModel.voiceState,
                audioPowerLevel: viewModel.currentAudioPowerLevel,
                isPressEnabled: viewModel.hasAllRequiredPermissions,
                onPressDown: {
                    Task { await viewModel.startListening() }
                },
                onPressUp: {
                    viewModel.stopListening()
                }
            )
            .frame(height: 220)
        }
    }
}
