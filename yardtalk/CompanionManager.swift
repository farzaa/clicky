//
//  CompanionManager.swift
//  yardtalk
//
//  App-level state for the YardTalk skeleton phase. Tracks the four
//  permissions YardTalk needs (mic, screen recording, screen content,
//  accessibility) and exposes them to the menu bar panel. The Clicky
//  push-to-talk pipeline that previously lived here was stripped — session
//  recording, transcription (FluidAudio), and synthesis (Claude) ship in
//  later commits.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false
    @Published private(set) var isRequestingScreenContent = false

    /// Project registry — owns the on-disk projects and active selection.
    /// `@Observable` rather than `@Published`, so SwiftUI views that read its
    /// properties get tracked independently of CompanionManager's republish.
    let projectStore = ProjectStore()

    private var permissionPollTimer: Timer?

    var allPermissionsGranted: Bool {
        hasAccessibilityPermission
            && hasScreenRecordingPermission
            && hasMicrophonePermission
            && hasScreenContentPermission
    }

    func start() {
        refreshAllPermissions()
        promptForMicrophoneIfNotDetermined()
        startPermissionPolling()
        print("🔑 YardTalk start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
    }

    func stop() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
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
