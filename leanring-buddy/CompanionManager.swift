//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import CoreGraphics
import Foundation

#if canImport(PostHog)
import PostHog
#endif

import ScreenCaptureKit
import Security
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle {
        didSet {
            if oldValue != voiceState {
                DotDebugLogger.log("voice.state", "changed", metadata: [
                    "from": String(describing: oldValue),
                    "to": String(describing: voiceState)
                ])
            }
            scheduleVoiceStateSafetyResetIfNeeded()
        }
    }
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasInputMonitoringPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false
    @Published private(set) var screenContentPermissionProblem: String?

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary.
    private static var workerBaseURL: String {
        AppBundleConfiguration.proxyBaseURLString()
    }
    private nonisolated static let persistentContentCaptureEntitlementKey = "com.apple.developer.persistent-content-capture"

    private lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: selectedModel)
    }()

    private lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient(proxyURL: "\(Self.workerBaseURL)/tts")
    }()

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?
    private var voiceStateSafetyResetTask: Task<Void, Never>?

    /// True when all required permissions are granted. Used by the panel to show
    /// a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission
            && hasInputMonitoringPermission
            && hasScreenRecordingPermission
            && hasMicrophonePermission
            && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-sonnet-4-6"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = model
    }

    /// User preference for whether the Dot cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isDotCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isDotCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isDotCursorEnabled")

    func setDotCursorEnabled(_ enabled: Bool) {
        isDotCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isDotCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        #if canImport(PostHog)
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])
        #endif

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        DotDebugLogger.markLaunch()
        refreshAllPermissions()
        // Intentionally NOT validating SCK permission on launch. macOS has no
        // documented preflight for SCK, so any validation requires actually
        // calling SCShareableContent / SCScreenshotManager — which pops the
        // system "Open Settings" dialog if permission is missing. Doing that
        // on every launch led to dialog spam. Instead, the first real capture
        // attempt detects denial and updates the UI accordingly.
        let hasPersistentContentCaptureEntitlement = Self.hasPersistentContentCaptureEntitlement()
        print("🔑 Dot start — accessibility: \(hasAccessibilityPermission), inputMonitoring: \(hasInputMonitoringPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), persistentCaptureEntitlement: \(hasPersistentContentCaptureEntitlement), onboarded: \(hasCompletedOnboarding)")
        DotDebugLogger.log("app.start", "starting companion manager", metadata: [
            "accessibility": hasAccessibilityPermission,
            "inputMonitoring": hasInputMonitoringPermission,
            "screenRecording": hasScreenRecordingPermission,
            "microphone": hasMicrophonePermission,
            "screenContent": hasScreenContentPermission,
            "persistentContentCaptureEntitlement": hasPersistentContentCaptureEntitlement,
            "allPermissionsGranted": allPermissionsGranted,
            "hasCompletedOnboarding": hasCompletedOnboarding,
            "isDotCursorEnabled": isDotCursorEnabled,
            "workerBaseURL": Self.workerBaseURL
        ])
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isDotCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .dotDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        DotAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .dotDismissPanel, object: nil)
        DotAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Dot: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Dot: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func stop() {
        DotDebugLogger.log("app.stop", "stopping companion manager", metadata: interactionStateLogMetadata())
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
        voiceStateSafetyResetTask?.cancel()
        voiceStateSafetyResetTask = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadInputMonitoring = hasInputMonitoringPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasLiveAccessibility = WindowPositionManager.hasLiveAccessibilityPermission()
        let currentlyHasPersistentContentCaptureEntitlement = Self.hasPersistentContentCaptureEntitlement()
        hasAccessibilityPermission = currentlyHasLiveAccessibility

        // Input Monitoring detection is awkward on macOS: CGPreflightListenEventAccess()
        // famously returns a stale `false` even after the user grants permission in
        // System Settings, until the process is killed and relaunched. We work around
        // that by also attempting to start the real event tap whenever Accessibility
        // is granted and we don't yet have a live tap. CGEvent.tapCreate only succeeds
        // when permission is truly granted, so its success/failure is the actual truth.
        let preflightSaysHasInputMonitoring = WindowPositionManager.hasInputMonitoringPermission()
        if currentlyHasLiveAccessibility && !globalPushToTalkShortcutMonitor.isEventTapActive {
            globalPushToTalkShortcutMonitor.start()
        }
        let currentlyHasInputMonitoring = globalPushToTalkShortcutMonitor.isEventTapActive
            || preflightSaysHasInputMonitoring
        hasInputMonitoringPermission = currentlyHasInputMonitoring

        if !(currentlyHasLiveAccessibility && currentlyHasInputMonitoring) {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            DotAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadInputMonitoring && hasInputMonitoringPermission {
            DotAnalytics.trackPermissionGranted(permission: "input_monitoring")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            DotAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            DotAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission has no cheap public preflight API. We keep a
        // persisted grant for UI responsiveness, then validate it once per launch
        // with a real low-resolution capture probe.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermissionV2")
        }
        // Debug: log permission state after all live and persisted permission
        // sources have been reconciled.
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadInputMonitoring != hasInputMonitoringPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission
            || previouslyHadAll != allPermissionsGranted {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), inputMonitoring: \(hasInputMonitoringPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
            DotDebugLogger.log("permissions.refresh", "permission state changed", metadata: [
                "accessibility.previous": previouslyHadAccessibility,
                "accessibility.current": hasAccessibilityPermission,
                "accessibility.live": currentlyHasLiveAccessibility,
                "inputMonitoring.previous": previouslyHadInputMonitoring,
                "inputMonitoring.current": hasInputMonitoringPermission,
                "screenRecording.previous": previouslyHadScreenRecording,
                "screenRecording.current": hasScreenRecordingPermission,
                "microphone.previous": previouslyHadMicrophone,
                "microphone.current": hasMicrophonePermission,
                "screenContent.current": hasScreenContentPermission,
                "persistentContentCaptureEntitlement": currentlyHasPersistentContentCaptureEntitlement,
                "screenContentProblem": screenContentPermissionProblem ?? "none",
                "all.previous": previouslyHadAll,
                "all.current": allPermissionsGranted
            ])
        }

        if !previouslyHadAll && allPermissionsGranted {
            DotAnalytics.trackAllPermissionsGranted()

            if hasCompletedOnboarding && isDotCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
                DotDebugLogger.log("overlay", "shown after permissions became granted")
            }
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let probeResult = try await Self.probeScreenContentPermission()
                print("🔑 Screen content capture result — width: \(probeResult.width), height: \(probeResult.height), didCapture: \(probeResult.didCapture)")
                DotDebugLogger.log("permissions.screenContent", "capture permission probe completed", metadata: [
                    "width": probeResult.width,
                    "height": probeResult.height,
                    "didCapture": probeResult.didCapture
                ])
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard probeResult.didCapture else {
                        markScreenContentCaptureUnavailable(reason: "permission probe returned empty capture")
                        return
                    }
                    hasScreenContentPermission = true
                    screenContentPermissionProblem = nil
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermissionV2")
                    DotAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isDotCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                DotDebugLogger.log("permissions.screenContent", "capture permission probe failed", metadata: [
                    "error": error.localizedDescription
                ])
                await MainActor.run {
                    markScreenContentCaptureUnavailable(
                        reason: "capture permission probe failed",
                        errorDescription: Self.diagnosticDescription(forScreenCaptureError: error)
                    )
                    isRequestingScreenContent = false
                }
            }
        }
    }

    /// Opens the System Settings pane where the user grants Screen & System
    /// Audio Recording. The URL has remained stable across the macOS 14 → 15
    /// rename of the pane label.
    func openScreenRecordingSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Quits and relaunches the running app. Required after the user grants
    /// Screen & System Audio Recording, because ScreenCaptureKit binds the TCC
    /// decision to the process's audit token at launch — there is no API to
    /// re-bind a freshly granted permission within a running process on
    /// macOS 14.2+ / 15.x.
    func relaunchAppAfterPermissionChange() {
        DotDebugLogger.log("permissions.screenContent", "relaunching to pick up freshly granted permission")
        let appBundleURL = Bundle.main.bundleURL
        let openConfiguration = NSWorkspace.OpenConfiguration()
        openConfiguration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: appBundleURL, configuration: openConfiguration) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Private

    private enum ScreenContentCaptureAccessError: LocalizedError {
        case missingPersistentContentCaptureEntitlement

        var errorDescription: String? {
            switch self {
            case .missingPersistentContentCaptureEntitlement:
                return CompanionManager.missingPersistentContentCaptureEntitlementDescription
            }
        }
    }

    private struct ScreenContentPermissionProbeResult {
        let width: Int
        let height: Int

        var didCapture: Bool {
            width > 0 && height > 0
        }
    }

    private nonisolated static var missingPersistentContentCaptureEntitlementDescription: String {
        "This build is not signed with Apple's \(persistentContentCaptureEntitlementKey) entitlement."
    }

    private nonisolated static func hasPersistentContentCaptureEntitlement() -> Bool {
        var currentCode: SecCode?
        let copySelfStatus = SecCodeCopySelf(SecCSFlags(rawValue: 0), &currentCode)
        guard copySelfStatus == errSecSuccess, let currentCode else {
            return false
        }

        var staticCode: SecStaticCode?
        let copyStaticCodeStatus = SecCodeCopyStaticCode(currentCode, SecCSFlags(rawValue: 0), &staticCode)
        guard copyStaticCodeStatus == errSecSuccess, let staticCode else {
            return false
        }

        var signingInformation: CFDictionary?
        let signingInformationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        )
        guard signingInformationStatus == errSecSuccess,
              let signingInformationDictionary = signingInformation as? [String: Any],
              let entitlements = signingInformationDictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else {
            return false
        }

        return entitlements[persistentContentCaptureEntitlementKey] as? Bool == true
    }

    private nonisolated static func diagnosticDescription(forScreenCaptureError error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == SCStreamError.errorDomain,
           let screenCaptureErrorCode = SCStreamError.Code(rawValue: nsError.code) {
            switch screenCaptureErrorCode {
            case .missingEntitlements:
                return missingPersistentContentCaptureEntitlementDescription
            case .userDeclined:
                return "macOS denied ScreenCaptureKit display capture even though Screen Recording may appear enabled."
            default:
                return "\(screenCaptureErrorCode): \(error.localizedDescription)"
            }
        }

        return error.localizedDescription
    }

    /// Performs a real ScreenCaptureKit capture as a permission probe.
    /// macOS does not expose a documented preflight for SCK, so calling the
    /// real API and observing whether it throws is the only reliable signal.
    /// CoreGraphics is intentionally not used as a fallback here because it
    /// "succeeds" with a wallpaper-only image when SCK permission is missing,
    /// which would mark the permission as granted when it isn't.
    private nonisolated static func probeScreenContentPermission() async throws -> ScreenContentPermissionProbeResult {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(
                domain: "CompanionScreenContentPermission",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No display available for screen content permission probe"]
            )
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 320
        configuration.height = 240

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return ScreenContentPermissionProbeResult(width: image.width, height: image.height)
    }

    private func markScreenContentCaptureUnavailable(reason: String, errorDescription: String? = nil) {
        hasScreenContentPermission = false
        UserDefaults.standard.set(false, forKey: "hasScreenContentPermissionV2")
        screenContentPermissionProblem = Self.screenContentProblemDescription(
            reason: reason,
            errorDescription: errorDescription
        )
        DotDebugLogger.log("permissions.screenContent", "marked revoked", metadata: [
            "reason": reason,
            "error": errorDescription ?? "none"
        ])
    }

    private static func screenContentProblemDescription(reason: String, errorDescription: String? = nil) -> String {
        let combinedDescription = "\(reason) \(errorDescription ?? "")".lowercased()
        if combinedDescription.contains("persistent-content-capture")
            || combinedDescription.contains("persistent content capture")
            || combinedDescription.contains("missing entitlement") {
            return "Install a production-signed build with persistent capture."
        }
        if combinedDescription.contains("declined") || combinedDescription.contains("denied") {
            // Sequoia (macOS 15) renamed the relevant pane to "Screen & System Audio Recording".
            // SCK can't pick up a freshly-granted permission until the process restarts, so the
            // recovery flow is always: enable in Settings, then relaunch Dot.
            return "Enable Screen & System Audio Recording for Dot in System Settings, then relaunch."
        }
        return "Screen capture check failed; see log."
    }

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        DotDebugLogger.log("permissions.microphone", "requesting microphone access")
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
                DotDebugLogger.log("permissions.microphone", "microphone access prompt completed", metadata: [
                    "granted": granted
                ])
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                DotDebugLogger.log("dictation.observable", "recording state update", metadata: [
                    "isRecordingKeyboard": isRecording,
                    "isFinalizing": isFinalizing,
                    "isPreparing": isPreparing,
                    "voiceState": String(describing: self.voiceState)
                ])
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        DotDebugLogger.log("shortcut.transition", "received", metadata: interactionStateLogMetadata(extra: [
            "transition": String(describing: transition)
        ]))

        switch transition {
        case .pressed:
            if buddyDictationManager.isDictationInProgress {
                print("⚠️ Companion: clearing stale dictation session before starting a new one.")
                DotDebugLogger.log("shortcut.transition", "clearing stale dictation before new press", metadata: interactionStateLogMetadata())
                buddyDictationManager.cancelCurrentDictation(preserveDraftText: false)
                voiceState = .idle
            }

            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else {
                DotDebugLogger.log("shortcut.transition", "ignored press during onboarding video")
                return
            }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isDotCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .dotDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            elevenLabsTTSClient.stopPlayback()
            clearDetectedElementLocation()
            DotDebugLogger.log("shortcut.transition", "prepared for new push-to-talk session", metadata: interactionStateLogMetadata())

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            DotAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            DotDebugLogger.log("shortcut.transition", "starting keyboard dictation task")
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        DotDebugLogger.log("dictation.final", "companion received transcript", metadata: [
                            "transcriptLength": finalTranscript.count
                        ])
                        DotAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        if self?.handleDirectLocalMediaCommandIfRecognized(transcript: finalTranscript) != true {
                            self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                        }
                    }
                )
                DotDebugLogger.log("shortcut.transition", "keyboard dictation task returned")
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            DotAnalytics.trackPushToTalkReleased()
            DotDebugLogger.log("shortcut.transition", "release handling started", metadata: interactionStateLogMetadata())
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
            DotDebugLogger.log("shortcut.transition", "release handling finished", metadata: interactionStateLogMetadata())
        case .none:
            break
        }
    }

    private func interactionStateLogMetadata(extra: [String: Any] = [:]) -> [String: Any] {
        var metadata: [String: Any] = [
            "voiceState": String(describing: voiceState),
            "dictationInProgress": buddyDictationManager.isDictationInProgress,
            "isPreparingToRecord": buddyDictationManager.isPreparingToRecord,
            "isRecordingKeyboard": buddyDictationManager.isRecordingFromKeyboardShortcut,
            "isFinalizingTranscript": buddyDictationManager.isFinalizingTranscript,
            "pendingKeyboardShortcutStartTask": pendingKeyboardShortcutStartTask != nil,
            "currentResponseTask": currentResponseTask != nil,
            "isOverlayVisible": isOverlayVisible
        ]

        for (key, value) in extra {
            metadata[key] = value
        }

        return metadata
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're dot, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag after your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    computer control:
    you can also actually click, type, or send global media controls. choose between pointing and acting based on the user's intent:
    - if the user asks where something is, how to do something, what something means, or asks for guidance, point at the relevant UI element and explain.
    - if the user asks you to operate the computer — click, open, press, select, choose, go to, focus, type, fill in, search for, pause media, skip music, or similar command language — perform the action.
    - if the action would submit, buy, send, delete, close unsaved work, change account/security settings, or trigger an externally visible side effect, do not perform it automatically. point and explain what would happen instead.
    - if the target is ambiguous or you cannot identify it confidently from the screenshot, point to the most likely target and explain the uncertainty instead of clicking.

    for media controls, prefer the global media command over clicking a music app. use [MEDIA:play_pause] for pause, play, resume, stop the music, or toggle playback. use [MEDIA:next] for skip or next track. use [MEDIA:previous] for previous track or go back. these send the mac's media keys, so they work even if the music app is hidden or on another space.

    when you click, append a click tag after the spoken text using the same screenshot coordinate space as pointing: [CLICK:x,y:label] or [CLICK:x,y:label:screenN].

    when you type text into the currently focused field, append: [TYPE:text to type]. for newlines in typed text, write \\n. don't put a closing square bracket inside typed text.

    when you need to press a special key or a keyboard shortcut (anything that isn't just typing characters), append: [KEY:keyname]. supported names are case-insensitive:
    - editing keys: backspace (also accepts delete), forwarddelete, return (also accepts enter), tab, space, escape
    - arrow keys: up, down, left, right
    - navigation: home, end, pageup, pagedown
    - letters a–z, digits 0–9
    - function keys f1 through f12
    - combine with modifiers using +: cmd, shift, ctrl, option (also accepts alt or opt). examples: [KEY:cmd+a], [KEY:cmd+shift+z], [KEY:ctrl+space]

    use [KEY:...] for ANY non-character keystroke. never try to express a special key as part of [TYPE:...] (TYPE only types literal characters and cannot send backspace, modifier shortcuts, or function keys).

    to clear all the text in a focused input, use this exact pattern: [KEY:cmd+a][KEY:backspace]. to clear and replace text in an input you can see: [CLICK:x,y:input field][KEY:cmd+a][KEY:backspace][TYPE:new content].

    if the task needs multiple actions, append all action tags in execution order, for example: [CLICK:430,220:name field][TYPE:hello].

    action tags and point tags are hidden control tags. write normal spoken text first, then append the tags. never read or explain the tags.

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    - user asks you to click the search field: "i'll click the search field. [POINT:520,80:search field][CLICK:520,80:search field]"
    - user says open the settings tab: "opening settings. [POINT:940,74:settings][CLICK:940,74:settings]"
    - user asks you to type a phrase into the focused field: "i'll type that in. [POINT:none][TYPE:hello from dot]"
    - user asks you to delete or clear what they typed in the chat box at (430,520): "clearing it. [POINT:none][CLICK:430,520:chat box][KEY:cmd+a][KEY:backspace]"
    - user asks you to send the message currently in the focused input: "sending. [POINT:none][KEY:return]"
    - user asks you to undo the last thing: "undoing. [POINT:none][KEY:cmd+z]"
    - user asks you to close the current tab: "closing the tab. [POINT:none][KEY:cmd+w]"
    - user asks you to stop the music: "done. [POINT:none][MEDIA:play_pause]"
    - user asks you to skip the song: "skipping. [POINT:none][MEDIA:next]"
    - user asks you to go back a track: "going back. [POINT:none][MEDIA:previous]"
    """

    private func handleDirectLocalMediaCommandIfRecognized(transcript: String) -> Bool {
        guard let mediaControlCommand = Self.parseDirectLocalMediaCommand(from: transcript) else {
            DotDebugLogger.log("media.direct", "no direct local media command matched", metadata: [
                "transcriptLength": transcript.count
            ])
            return false
        }

        DotDebugLogger.log("media.direct", "matched direct local media command", metadata: [
            "command": mediaControlCommand.rawValue,
            "transcriptLength": transcript.count
        ])
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()

        currentResponseTask = Task {
            voiceState = .processing
            CompanionComputerController.pressMediaControl(mediaControlCommand)

            await saveConversationAndSpeakResponse(
                transcript: transcript,
                spokenText: mediaControlCommand.spokenConfirmation
            )

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }

        return true
    }

    private static func parseDirectLocalMediaCommand(from transcript: String) -> CompanionMediaControlCommand? {
        let normalizedTranscript = normalizeDirectCommandTranscript(transcript)
        guard !normalizedTranscript.isEmpty else { return nil }

        let politePrefixPattern = #"(?:(?:can|could|would|will) you\s+)?(?:please\s+)?"#
        let mediaObjectPattern = #"(?:the\s+|this\s+|that\s+)?(?:music|song|track|audio|playback|video|movie|media)"#
        let trackObjectPattern = #"(?:the\s+|this\s+|that\s+|a\s+)?(?:song|track)"#

        let nextTrackPatterns = [
            #"^\#(politePrefixPattern)(?:skip|next)\s+\#(trackObjectPattern)$"#,
            #"^\#(politePrefixPattern)(?:skip|next)\s+\#(mediaObjectPattern)$"#,
            #"^\#(politePrefixPattern)(?:go\s+to\s+)?(?:the\s+)?next\s+\#(trackObjectPattern)$"#
        ]
        if normalizedTranscriptMatchesAnyRegularExpressionPattern(
            normalizedTranscript,
            patterns: nextTrackPatterns
        ) {
            return .nextTrack
        }

        let previousTrackPatterns = [
            #"^\#(politePrefixPattern)(?:previous|prev|last)\s+\#(trackObjectPattern)$"#,
            #"^\#(politePrefixPattern)(?:go\s+)?back\s+(?:one\s+|a\s+)?(?:song|track)$"#,
            #"^\#(politePrefixPattern)play\s+(?:the\s+)?(?:previous|prev|last)\s+(?:song|track)$"#
        ]
        if normalizedTranscriptMatchesAnyRegularExpressionPattern(
            normalizedTranscript,
            patterns: previousTrackPatterns
        ) {
            return .previousTrack
        }

        let playPausePatterns = [
            #"^\#(politePrefixPattern)(?:pause|resume)$"#,
            #"^\#(politePrefixPattern)(?:pause|play|resume|stop)\s+\#(mediaObjectPattern)$"#,
            #"^\#(politePrefixPattern)(?:pause|play|resume|stop)\s+(?:it|this)$"#,
            #"^\#(politePrefixPattern)(?:turn\s+off|shut\s+off|toggle)\s+\#(mediaObjectPattern)$"#
        ]
        if normalizedTranscriptMatchesAnyRegularExpressionPattern(
            normalizedTranscript,
            patterns: playPausePatterns
        ) {
            return .playPause
        }

        return nil
    }

    private static func normalizeDirectCommandTranscript(_ transcript: String) -> String {
        let lowercaseTranscript = transcript.lowercased()
        let punctuationCollapsedTranscript = lowercaseTranscript.replacingOccurrences(
            of: #"[^a-z0-9\s]"#,
            with: " ",
            options: .regularExpression
        )
        let whitespaceCollapsedTranscript = punctuationCollapsedTranscript.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        return whitespaceCollapsedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedTranscriptMatchesAnyRegularExpressionPattern(
        _ normalizedTranscript: String,
        patterns: [String]
    ) -> Bool {
        for pattern in patterns {
            guard let regularExpression = try? NSRegularExpression(pattern: pattern) else {
                continue
            }

            let fullRange = NSRange(normalizedTranscript.startIndex..., in: normalizedTranscript)
            if regularExpression.firstMatch(in: normalizedTranscript, range: fullRange) != nil {
                return true
            }
        }

        return false
    }

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        DotDebugLogger.log("response.pipeline", "starting Claude screenshot response", metadata: [
            "transcriptLength": transcript.count,
            "conversationHistoryCount": conversationHistory.count
        ])

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                DotDebugLogger.log("response.pipeline", "captured screens", metadata: [
                    "screenCount": screenCaptures.count,
                    "labels": screenCaptures.map(\.label).joined(separator: ",")
                ])

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Pass conversation history so Claude remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.companionVoiceResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    onTextChunk: { _ in
                        // No streaming text display — spinner stays until TTS plays
                    }
                )
                DotDebugLogger.log("response.pipeline", "Claude response received", metadata: [
                    "responseLength": fullResponseText.count
                ])

                guard !Task.isCancelled else { return }

                // Parse hidden computer-control tags before the point tag so
                // [POINT:...] can still be the last remaining control directive.
                let computerControlParseResult = Self.parseComputerControlActions(from: fullResponseText)
                let parseResult = Self.parsePointingCoordinates(from: computerControlParseResult.spokenText)
                let spokenText = parseResult.spokenText
                DotDebugLogger.log("response.pipeline", "parsed control tags", metadata: [
                    "spokenTextLength": spokenText.count,
                    "actionCount": computerControlParseResult.actions.count,
                    "hasPointCoordinate": parseResult.coordinate != nil,
                    "pointLabel": parseResult.elementLabel ?? "none",
                    "pointScreen": parseResult.screenNumber ?? -1
                ])

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                let hasClickAction = computerControlParseResult.actions.contains { action in
                    if case .click = action {
                        return true
                    }
                    return false
                }
                if hasPointCoordinate || hasClickAction {
                    voiceState = .idle
                }

                if let pointCoordinate = parseResult.coordinate,
                   let mappedPointLocation = Self.mapScreenshotCoordinateToGlobalScreenLocation(
                    pointCoordinate,
                    screenNumber: parseResult.screenNumber,
                    screenCaptures: screenCaptures
                   ) {
                    detectedElementScreenLocation = mappedPointLocation.globalLocation
                    detectedElementDisplayFrame = mappedPointLocation.displayFrame
                    DotAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                    DotDebugLogger.log("response.pipeline", "mapped point coordinate", metadata: [
                        "x": Int(pointCoordinate.x),
                        "y": Int(pointCoordinate.y),
                        "label": parseResult.elementLabel ?? "element",
                        "screen": parseResult.screenNumber ?? -1,
                        "globalX": Int(mappedPointLocation.globalLocation.x),
                        "globalY": Int(mappedPointLocation.globalLocation.y)
                    ])
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                    DotDebugLogger.log("response.pipeline", "no mapped point coordinate", metadata: [
                        "label": parseResult.elementLabel ?? "none"
                    ])
                }

                await performComputerControlActions(
                    computerControlParseResult.actions,
                    screenCaptures: screenCaptures
                )

                await saveConversationAndSpeakResponse(
                    transcript: transcript,
                    spokenText: spokenText
                )
            } catch is CancellationError {
                // User spoke again — response was interrupted
                DotDebugLogger.log("response.pipeline", "cancelled")
            } catch {
                DotAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                DotDebugLogger.log("response.pipeline", "failed", metadata: [
                    "error": error.localizedDescription
                ])
                speakResponsePipelineErrorFallback(for: error)
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
                DotDebugLogger.log("response.pipeline", "finished", metadata: interactionStateLogMetadata())
            }
        }
    }

    private func saveConversationAndSpeakResponse(transcript: String, spokenText: String) async {
        // Save this exchange to conversation history (with control tags stripped
        // so they don't confuse future context)
        conversationHistory.append((
            userTranscript: transcript,
            assistantResponse: spokenText
        ))

        // Keep only the last 10 exchanges to avoid unbounded context growth
        if conversationHistory.count > 10 {
            conversationHistory.removeFirst(conversationHistory.count - 10)
        }

        print("🧠 Conversation history: \(conversationHistory.count) exchanges")
        DotDebugLogger.log("response.history", "saved conversation exchange", metadata: [
            "conversationHistoryCount": conversationHistory.count,
            "spokenTextLength": spokenText.count,
            "transcriptLength": transcript.count
        ])

        DotAnalytics.trackAIResponseReceived(response: spokenText)

        // Play the response via TTS. Keep the spinner (processing state)
        // until the audio actually starts playing, then switch to responding.
        if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                DotDebugLogger.log("tts", "starting ElevenLabs playback", metadata: [
                    "spokenTextLength": spokenText.count
                ])
                try await elevenLabsTTSClient.speakText(spokenText)
                // speakText returns after player.play() — audio is now playing
                voiceState = .responding
                DotDebugLogger.log("tts", "playback started")
            } catch {
                DotAnalytics.trackTTSError(error: error.localizedDescription)
                print("⚠️ ElevenLabs TTS error: \(error)")
                DotDebugLogger.log("tts", "playback failed", metadata: [
                    "error": error.localizedDescription
                ])
                speakSystemVoiceFallback(spokenText)
            }
        }
    }

    private func scheduleVoiceStateSafetyResetIfNeeded() {
        voiceStateSafetyResetTask?.cancel()
        voiceStateSafetyResetTask = nil

        let timeoutNanoseconds: UInt64?
        switch voiceState {
        case .idle:
            timeoutNanoseconds = nil
        case .listening:
            timeoutNanoseconds = 45_000_000_000
        case .processing:
            timeoutNanoseconds = 90_000_000_000
        case .responding:
            timeoutNanoseconds = 90_000_000_000
        }

        guard let timeoutNanoseconds else { return }
        let voiceStateWhenTimerStarted = voiceState
        DotDebugLogger.log("voice.safety", "scheduled safety reset", metadata: [
            "voiceState": String(describing: voiceStateWhenTimerStarted),
            "timeoutSeconds": Double(timeoutNanoseconds) / 1_000_000_000
        ])

        voiceStateSafetyResetTask = Task {
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled else { return }
            guard voiceState == voiceStateWhenTimerStarted else { return }
            resetStuckInteractionAfterSafetyTimeout(stuckVoiceState: voiceStateWhenTimerStarted)
        }
    }

    private func resetStuckInteractionAfterSafetyTimeout(stuckVoiceState: CompanionVoiceState) {
        print("⚠️ Companion: resetting stuck \(stuckVoiceState) state after safety timeout.")
        DotDebugLogger.log("voice.safety", "resetting stuck interaction", metadata: interactionStateLogMetadata(extra: [
            "stuckVoiceState": String(describing: stuckVoiceState)
        ]))

        currentResponseTask?.cancel()
        currentResponseTask = nil
        pendingKeyboardShortcutStartTask?.cancel()
        pendingKeyboardShortcutStartTask = nil
        buddyDictationManager.cancelCurrentDictation(preserveDraftText: false)
        elevenLabsTTSClient.stopPlayback()
        clearDetectedElementLocation()
        voiceState = .idle
        scheduleTransientHideIfNeeded()
    }

    /// If the cursor is in transient mode (user toggled "Show Dot" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isDotCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        DotDebugLogger.log("overlay.transient", "scheduled transient hide")
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while elevenLabsTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
            DotDebugLogger.log("overlay.transient", "transient overlay hidden")
        }
    }

    /// Uses macOS system TTS as the last-resort voice path so failures in
    /// Claude, ScreenCaptureKit, or ElevenLabs do not get misreported as a
    /// credits problem.
    private func speakSystemVoiceFallback(_ utterance: String) {
        guard !utterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    private func speakResponsePipelineErrorFallback(for error: Error) {
        if Self.isScreenCaptureTCCError(error) {
            markScreenContentCaptureUnavailable(
                reason: "screen capture failed during response pipeline",
                errorDescription: Self.diagnosticDescription(forScreenCaptureError: error)
            )

            if Self.hasPersistentContentCaptureEntitlement() {
                speakSystemVoiceFallback("macOS blocked me from seeing your screen. Confirm Screen Recording is enabled for Dot, then quit and reopen Dot.")
            } else {
                speakSystemVoiceFallback("This Dot build is missing Apple's persistent screen capture entitlement.")
            }
            return
        }

        speakSystemVoiceFallback("I hit an app error before I could answer. Check the Dot development log for the exact failure.")
    }

    private static func isScreenCaptureTCCError(_ error: Error) -> Bool {
        // The capture utility now throws a typed permissionDenied case when SCK
        // reports the user has not granted Screen & System Audio Recording.
        // Fall back to substring matching for any older / wrapped error shapes.
        if case CompanionScreenCaptureError.permissionDenied = error {
            return true
        }
        let errorDescription = error.localizedDescription.lowercased()
        return errorDescription.contains("tcc")
            || errorDescription.contains("display capture")
            || errorDescription.contains("window capture")
            || errorDescription.contains("screen capture")
            || errorDescription.contains("declined")
    }

    // MARK: - Computer Control

    private enum CompanionComputerControlAction {
        case click(coordinate: CGPoint, elementLabel: String?, screenNumber: Int?)
        case mediaControl(CompanionMediaControlCommand)
        case typeText(String)
        case keyPress(CompanionKeystroke)
    }

    private struct ComputerControlActionParseResult {
        let spokenText: String
        let actions: [CompanionComputerControlAction]
    }

    private struct ComputerControlActionMatch {
        let utf16Location: Int
        let action: CompanionComputerControlAction
    }

    private struct MappedScreenLocation {
        let globalLocation: CGPoint
        let displayFrame: CGRect
    }

    private func performComputerControlActions(
        _ actions: [CompanionComputerControlAction],
        screenCaptures: [CompanionScreenCapture]
    ) async {
        guard !actions.isEmpty else { return }
        DotDebugLogger.log("computer.actions", "executing actions", metadata: [
            "actionCount": actions.count
        ])
        var estimatedBlueCursorStartLocation = NSEvent.mouseLocation

        for action in actions {
            guard !Task.isCancelled else { return }

            switch action {
            case .click(let coordinate, let elementLabel, let screenNumber):
                DotDebugLogger.log("computer.actions", "click action requested", metadata: [
                    "x": Int(coordinate.x),
                    "y": Int(coordinate.y),
                    "label": elementLabel ?? "element",
                    "screen": screenNumber ?? -1
                ])
                guard let mappedClickLocation = Self.mapScreenshotCoordinateToGlobalScreenLocation(
                    coordinate,
                    screenNumber: screenNumber,
                    screenCaptures: screenCaptures
                ) else {
                    print("⚠️ Computer control: could not map click coordinate.")
                    DotDebugLogger.log("computer.actions", "could not map click coordinate", metadata: [
                        "x": Int(coordinate.x),
                        "y": Int(coordinate.y),
                        "screen": screenNumber ?? -1
                    ])
                    continue
                }

                detectedElementBubbleText = elementLabel.map { "clicking \($0)" } ?? "clicking"
                detectedElementScreenLocation = mappedClickLocation.globalLocation
                detectedElementDisplayFrame = mappedClickLocation.displayFrame

                let blueCursorFlightDelayNanoseconds = Self.estimatedBlueCursorFlightDelayNanoseconds(
                    from: estimatedBlueCursorStartLocation,
                    to: mappedClickLocation.globalLocation
                )
                try? await Task.sleep(nanoseconds: blueCursorFlightDelayNanoseconds)

                CompanionComputerController.click(atAppKitScreenLocation: mappedClickLocation.globalLocation)
                estimatedBlueCursorStartLocation = mappedClickLocation.globalLocation
                print("🖱️ Computer control: clicked \"\(elementLabel ?? "element")\" at (\(Int(coordinate.x)), \(Int(coordinate.y)))")
                DotDebugLogger.log("computer.actions", "click action completed", metadata: [
                    "x": Int(coordinate.x),
                    "y": Int(coordinate.y),
                    "label": elementLabel ?? "element",
                    "screen": screenNumber ?? -1,
                    "globalX": Int(mappedClickLocation.globalLocation.x),
                    "globalY": Int(mappedClickLocation.globalLocation.y)
                ])
                try? await Task.sleep(nanoseconds: 180_000_000)

            case .mediaControl(let mediaControlCommand):
                DotDebugLogger.log("computer.actions", "media action requested", metadata: [
                    "command": mediaControlCommand.rawValue
                ])
                CompanionComputerController.pressMediaControl(mediaControlCommand)
                print("🎛️ Computer control: executed \(mediaControlCommand.logDescription)")
                DotDebugLogger.log("computer.actions", "media action completed", metadata: [
                    "command": mediaControlCommand.rawValue
                ])
                try? await Task.sleep(nanoseconds: 120_000_000)

            case .typeText(let text):
                DotDebugLogger.log("computer.actions", "type action requested", metadata: [
                    "characterCount": text.count
                ])
                CompanionComputerController.typeText(text)
                print("⌨️ Computer control: typed \(text.count) character(s)")
                DotDebugLogger.log("computer.actions", "type action completed", metadata: [
                    "characterCount": text.count
                ])
                try? await Task.sleep(nanoseconds: 80_000_000)

            case .keyPress(let keystroke):
                DotDebugLogger.log("computer.actions", "key action requested", metadata: [
                    "keystroke": keystroke.humanReadableDescription
                ])
                CompanionComputerController.pressKeystroke(keystroke)
                print("⌨️ Computer control: pressed \(keystroke.humanReadableDescription)")
                DotDebugLogger.log("computer.actions", "key action completed", metadata: [
                    "keystroke": keystroke.humanReadableDescription
                ])
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
        DotDebugLogger.log("computer.actions", "finished actions", metadata: [
            "actionCount": actions.count
        ])
    }

    private static func estimatedBlueCursorFlightDelayNanoseconds(
        from startLocation: CGPoint,
        to targetLocation: CGPoint
    ) -> UInt64 {
        let distance = hypot(
            targetLocation.x - startLocation.x,
            targetLocation.y - startLocation.y
        )
        let flightDurationSeconds = min(max(distance / 800.0, 0.6), 1.4)
        let clickAfterArrivalPaddingSeconds = 0.08
        return UInt64((flightDurationSeconds + clickAfterArrivalPaddingSeconds) * 1_000_000_000)
    }

    private static func parseComputerControlActions(from responseText: String) -> ComputerControlActionParseResult {
        let clickPattern = #"\[CLICK:(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?\]"#
        let mediaPattern = #"\[MEDIA:([a-zA-Z_\- ]+)\]"#
        let typePattern = #"\[TYPE:([^\]]*)\]"#
        let keyPattern = #"\[KEY:([^\]]+)\]"#
        let nonePatterns = [
            #"\[CLICK:none\]"#,
            #"\[MEDIA:none\]"#,
            #"\[TYPE:none\]"#,
            #"\[KEY:none\]"#
        ]
        var actionMatches: [ComputerControlActionMatch] = []

        if let clickRegex = try? NSRegularExpression(pattern: clickPattern, options: [.caseInsensitive]) {
            let matches = clickRegex.matches(
                in: responseText,
                range: NSRange(responseText.startIndex..., in: responseText)
            )

            for match in matches {
                guard let xRange = Range(match.range(at: 1), in: responseText),
                      let yRange = Range(match.range(at: 2), in: responseText),
                      let x = Double(responseText[xRange]),
                      let y = Double(responseText[yRange]) else {
                    continue
                }

                var elementLabel: String?
                if let labelRange = Range(match.range(at: 3), in: responseText) {
                    elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
                }

                var screenNumber: Int?
                if let screenRange = Range(match.range(at: 4), in: responseText) {
                    screenNumber = Int(responseText[screenRange])
                }

                actionMatches.append(ComputerControlActionMatch(
                    utf16Location: match.range.location,
                    action: .click(
                        coordinate: CGPoint(x: x, y: y),
                        elementLabel: elementLabel,
                        screenNumber: screenNumber
                    )
                ))
            }
        }

        if let mediaRegex = try? NSRegularExpression(pattern: mediaPattern, options: [.caseInsensitive]) {
            let matches = mediaRegex.matches(
                in: responseText,
                range: NSRange(responseText.startIndex..., in: responseText)
            )

            for match in matches {
                guard let mediaControlRange = Range(match.range(at: 1), in: responseText),
                      let mediaControlCommand = CompanionMediaControlCommand(
                        controlTagValue: String(responseText[mediaControlRange])
                      ) else {
                    continue
                }

                actionMatches.append(ComputerControlActionMatch(
                    utf16Location: match.range.location,
                    action: .mediaControl(mediaControlCommand)
                ))
            }
        }

        if let typeRegex = try? NSRegularExpression(pattern: typePattern, options: [.caseInsensitive]) {
            let matches = typeRegex.matches(
                in: responseText,
                range: NSRange(responseText.startIndex..., in: responseText)
            )

            for match in matches {
                guard let textRange = Range(match.range(at: 1), in: responseText) else {
                    continue
                }

                let typedText = String(responseText[textRange])
                    .replacingOccurrences(of: "\\n", with: "\n")

                actionMatches.append(ComputerControlActionMatch(
                    utf16Location: match.range.location,
                    action: .typeText(typedText)
                ))
            }
        }

        if let keyRegex = try? NSRegularExpression(pattern: keyPattern, options: [.caseInsensitive]) {
            let matches = keyRegex.matches(
                in: responseText,
                range: NSRange(responseText.startIndex..., in: responseText)
            )

            for match in matches {
                guard let keySpecRange = Range(match.range(at: 1), in: responseText) else {
                    continue
                }

                let rawKeySpec = String(responseText[keySpecRange])
                guard let parsedKeystroke = CompanionComputerController.parseKeystroke(fromKeySpec: rawKeySpec) else {
                    DotDebugLogger.log("computer.actions", "ignoring unparseable KEY tag", metadata: [
                        "rawKeySpec": rawKeySpec
                    ])
                    continue
                }

                actionMatches.append(ComputerControlActionMatch(
                    utf16Location: match.range.location,
                    action: .keyPress(parsedKeystroke)
                ))
            }
        }

        var spokenText = responseText
        for pattern in [clickPattern, mediaPattern, typePattern, keyPattern] + nonePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            spokenText = regex.stringByReplacingMatches(
                in: spokenText,
                range: NSRange(spokenText.startIndex..., in: spokenText),
                withTemplate: ""
            )
        }

        let actions = actionMatches
            .sorted { $0.utf16Location < $1.utf16Location }
            .map(\.action)

        return ComputerControlActionParseResult(
            spokenText: spokenText.trimmingCharacters(in: .whitespacesAndNewlines),
            actions: actions
        )
    }

    private static func mapScreenshotCoordinateToGlobalScreenLocation(
        _ screenshotCoordinate: CGPoint,
        screenNumber: Int?,
        screenCaptures: [CompanionScreenCapture]
    ) -> MappedScreenLocation? {
        let targetScreenCapture: CompanionScreenCapture? = {
            if let screenNumber,
               screenNumber >= 1 && screenNumber <= screenCaptures.count {
                return screenCaptures[screenNumber - 1]
            }
            return screenCaptures.first(where: { $0.isCursorScreen })
        }()

        guard let targetScreenCapture else { return nil }

        let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
        let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
        let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
        let displayFrame = targetScreenCapture.displayFrame

        guard screenshotWidth > 0, screenshotHeight > 0 else { return nil }

        let clampedX = max(0, min(screenshotCoordinate.x, screenshotWidth))
        let clampedY = max(0, min(screenshotCoordinate.y, screenshotHeight))
        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)
        let appKitY = displayHeight - displayLocalY

        return MappedScreenLocation(
            globalLocation: CGPoint(
                x: displayLocalX + displayFrame.origin.x,
                y: appKitY + displayFrame.origin.y
            ),
            displayFrame: displayFrame
        )
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Dot flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            DotAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            DotAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're dot, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
