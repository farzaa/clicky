//
//  CompanionManagerPermissionActions.swift
//  leanring-buddy
//
//  Permission refresh, polling, and ScreenCaptureKit grant actions for
//  CompanionManager. The manager owns state; this extension owns the macOS
//  permission side effects and telemetry.
//

import AppKit
import AVFoundation
import Foundation

@MainActor
extension CompanionManager {
    func refreshAllPermissions() {
        let previousPermissionState = companionPermissionState

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        setAccessibilityPermission(currentlyHasAccessibility)

        globalPushToTalkShortcutMonitor.start(accessibilityTrusted: currentlyHasAccessibility)

        setScreenRecordingPermission(WindowPositionManager.hasScreenRecordingPermission())

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        setMicrophonePermission(micAuthStatus == .authorized)

        let promptPermissionState = companionPermissionState
        let promptPermissionTransition = CompanionPermissionPolicy.transition(
            from: previousPermissionState,
            to: promptPermissionState
        )

        CompanionPermissionTelemetryRecorder.recordPromptPermissionChange(
            for: promptPermissionTransition,
            currentState: promptPermissionState
        )
        CompanionPermissionTelemetryRecorder.recordPromptPermissionGrantEvents(for: promptPermissionTransition)
        // Screen content permission is persisted after the SCShareableContent
        // picker returns real pixels, so regular permission polling can stay cheap.
        if !hasScreenContentPermission {
            setScreenContentPermission(UserDefaults.standard.bool(forKey: "hasScreenContentPermission"))
        }

        let finalPermissionTransition = CompanionPermissionPolicy.transition(
            from: previousPermissionState,
            to: companionPermissionState
        )
        CompanionPermissionTelemetryRecorder.recordAllPermissionsGrantedIfNeeded(for: finalPermissionTransition)
    }

    /// Triggers the macOS screen content picker by performing a dummy capture.
    /// Only dimensions are recorded; screenshot pixels never enter app state.
    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        setScreenContentRequestInFlight(true)
        Task {
            do {
                let probeOutcome = try await CompanionScreenContentPermissionProbe.run()
                switch probeOutcome {
                case .completed(let result):
                    CompanionPermissionTelemetryRecorder.recordScreenContentCaptureProbe(
                        width: result.width,
                        height: result.height,
                        didCapture: result.didCapture
                    )
                    await MainActor.run {
                        setScreenContentRequestInFlight(false)
                        guard result.didCapture else { return }
                        setScreenContentPermission(true)
                        UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                        CompanionPermissionTelemetryRecorder.recordPermissionGranted(.screenContent)

                        if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isSpiderCursorEnabled {
                            overlayWindowManager.hasShownOverlayBefore = true
                            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                            setOverlayVisible(true)
                        }
                    }
                case .noDisplayAvailable:
                    await MainActor.run { setScreenContentRequestInFlight(false) }
                }
            } catch {
                SpiderDiagnostics.event("screen content permission request failed")
                await MainActor.run { setScreenContentRequestInFlight(false) }
            }
        }
    }

    /// Polls permissions so the panel updates after the user grants them in
    /// System Settings. Screen Recording may still require an app restart.
    func startPermissionPolling() {
        setPermissionPollingTimer(Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        })
    }
}
