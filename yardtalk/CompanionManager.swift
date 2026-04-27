//
//  CompanionManager.swift
//  yardtalk
//
//  App-level state. Tracks the four permissions, owns the project + clip
//  stores, and hosts the SessionManager that drives hotkey-held recording.
//  The stores are `@Observable` rather than `@Published`, so SwiftUI views
//  that read their properties get tracked independently of CompanionManager.
//

import AVFoundation
import Combine
import Foundation
import Observation
import ScreenCaptureKit
import SwiftUI

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false
    @Published private(set) var isRequestingScreenContent = false

    let projectStore = ProjectStore()
    let clipStore = ClipStore()
    let transcriptionService = TranscriptionService()
    let sessionManager: SessionManager

    private var permissionPollTimer: Timer?

    var allPermissionsGranted: Bool {
        hasAccessibilityPermission
            && hasScreenRecordingPermission
            && hasMicrophonePermission
            && hasScreenContentPermission
    }

    init() {
        self.sessionManager = SessionManager(
            projectStore: projectStore,
            clipStore: clipStore,
            transcriptionService: transcriptionService
        )
        // Bring the clip list into sync with whichever project is active
        // when the app launches, then keep it in sync as the user picks
        // different projects.
        clipStore.setActiveProject(projectStore.activeProjectID)
        observeActiveProjectChanges()
    }

    func start() {
        refreshAllPermissions()
        promptForMicrophoneIfNotDetermined()
        startPermissionPolling()
        sessionManager.start()
        print("🔑 YardTalk start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
    }

    func stop() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        sessionManager.stop()
    }

    /// `withObservationTracking` only fires once per registration, so we
    /// re-arm inside the change handler. The closure can run on any actor;
    /// the `Task { @MainActor }` hop ensures we touch ClipStore from main.
    private func observeActiveProjectChanges() {
        withObservationTracking {
            _ = projectStore.activeProjectID
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.clipStore.setActiveProject(self.projectStore.activeProjectID)
                self.observeActiveProjectChanges()
            }
        }
    }

    func refreshAllPermissions() {
        let previouslyHadAll = allPermissionsGranted

        let previouslyHadAccessibility = hasAccessibilityPermission
        hasAccessibilityPermission = WindowPositionManager.hasAccessibilityPermission()
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            Analytics.trackPermissionGranted(permission: "accessibility")
        }

        let previouslyHadScreenRecording = hasScreenRecordingPermission
        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            Analytics.trackPermissionGranted(permission: "screen_recording")
        }

        let previouslyHadMicrophone = hasMicrophonePermission
        hasMicrophonePermission = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if !previouslyHadMicrophone && hasMicrophonePermission {
            Analytics.trackPermissionGranted(permission: "microphone")
        }

        // Screen content permission is persisted: once the SCShareableContent
        // picker has been approved, macOS won't re-prompt, so we cache the grant.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            Analytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker via a dummy screenshot capture.
    /// Once the user approves, the grant is persisted — macOS won't re-prompt.
    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { self.isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let didCapture = image.width > 0 && image.height > 0
                await MainActor.run {
                    self.isRequestingScreenContent = false
                    guard didCapture else { return }
                    self.hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    Analytics.trackPermissionGranted(permission: "screen_content")
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { self.isRequestingScreenContent = false }
            }
        }
    }

    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    private func startPermissionPolling() {
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }
}
