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
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(string.data(using: .utf8)!)
    }

    mutating func appendMultipartFormField(
        named fieldName: String,
        value: String,
        usingBoundary boundary: String
    ) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(fieldName)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }

    mutating func appendMultipartFileField(
        named fieldName: String,
        filename: String,
        mimeType: String,
        fileData: Data,
        usingBoundary boundary: String
    ) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: \(mimeType)\r\n\r\n")
        append(fileData)
        appendString("\r\n")
    }
}

enum CompanionPanelMode {
    case voiceAssistant
    case workspace
}

struct WorkspacePanelEntry: Identifiable {
    let id: String
    let entryName: String
    let entryPath: String
    let entryType: String
    let contentType: String?
    let sizeBytes: Int?

    var isDirectory: Bool {
        entryType == "directory"
    }
}

@MainActor
final class CompanionManager: ObservableObject {
    private static let backendAgentAuthTokenUserDefaultsKey = "backendAgentAuthToken"
    private static let backendAgentWorkspaceIDUserDefaultsKey = "backendAgentWorkspaceID"
    private static let backendAgentSessionIDUserDefaultsKey = "backendAgentSessionID"

    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false
    @Published var panelMode: CompanionPanelMode = .voiceAssistant
    @Published private(set) var isWorkspaceAuthenticated = false
    @Published private(set) var workspaceAuthenticatedUserEmailAddress: String?
    @Published private(set) var workspaceDisplayName: String?
    @Published private(set) var workspaceCurrentDirectoryPath: String = "/"
    @Published private(set) var workspaceEntries: [WorkspacePanelEntry] = []
    @Published private(set) var selectedWorkspaceFilePath: String?
    @Published private(set) var selectedWorkspaceFileTextPreview: String?
    @Published private(set) var isWorkspaceLoading = false
    @Published private(set) var isWorkspaceUploading = false
    @Published private(set) var workspaceStatusMessage: String?
    @Published private(set) var workspaceErrorMessage: String?

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

    private lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(proxyURL: "\(AppBundleConfiguration.backendBaseURL())/chat", model: selectedModel)
    }()

    private lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient(proxyURL: "\(AppBundleConfiguration.backendBaseURL())/tts")
    }()
    private let backendAgentSession = URLSession(configuration: .default)

    /// Conversation history passed to `/agent/runs` across turns.
    /// Messages include provider response IDs and tool call context.
    private var backendAgentConversationMessages: [[String: Any]] = []
    private var backendAgentAuthToken: String? = UserDefaults.standard.string(
        forKey: backendAgentAuthTokenUserDefaultsKey
    )
    private var backendAgentWorkspaceID: String? = UserDefaults.standard.string(
        forKey: backendAgentWorkspaceIDUserDefaultsKey
    )
    private var backendAgentSessionID: String? = UserDefaults.standard.string(
        forKey: backendAgentSessionIDUserDefaultsKey
    )
    private var cachedBackendAgentTools: [[String: Any]]?

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

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
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

    /// User preference for whether the Deb cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isDebCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isDebCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isDebCursorEnabled")

    func setDebCursorEnabled(_ enabled: Bool) {
        isDebCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isDebCursorEnabled")
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

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

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
        refreshAllPermissions()
        print("🔑 Deb start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
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
        if hasCompletedOnboarding && allPermissionsGranted && isDebCursorEnabled {
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
        NotificationCenter.default.post(name: .debDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        DebAnalytics.trackOnboardingStarted()

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
        NotificationCenter.default.post(name: .debDismissPanel, object: nil)
        DebAnalytics.trackOnboardingReplayed()
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
            print("⚠️ Deb: ff.mp3 not found in bundle")
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
            print("⚠️ Deb: Failed to play onboarding music: \(error)")
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
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            DebAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            DebAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            DebAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            DebAnalytics.trackAllPermissionsGranted()
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
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    DebAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isDebCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
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
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isDebCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .debDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            elevenLabsTTSClient.stopPlayback()
            clearDetectedElementLocation()

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
    

            DebAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        DebAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToAgentWithScreenshots(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            DebAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Workspace Panel

    func showVoiceAssistantPanel() {
        panelMode = .voiceAssistant
    }

    func showWorkspacePanel() {
        panelMode = .workspace
        Task {
            await refreshWorkspacePanel()
        }
    }

    func refreshWorkspacePanel() async {
        workspaceErrorMessage = nil
        workspaceStatusMessage = nil
        selectedWorkspaceFilePath = nil
        selectedWorkspaceFileTextPreview = nil

        guard let accessToken = backendAgentAuthToken else {
            clearWorkspacePanelSessionState()
            return
        }

        isWorkspaceLoading = true
        defer { isWorkspaceLoading = false }

        do {
            let authenticatedUserResponseObject = try await sendBackendRequest(
                path: "/auth/me",
                method: "GET",
                accessToken: accessToken,
                jsonBody: nil
            )
            guard let authenticatedUserPayload = authenticatedUserResponseObject as? [String: Any] else {
                throw NSError(
                    domain: "CompanionManager",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected object response for /auth/me."]
                )
            }
            workspaceAuthenticatedUserEmailAddress = authenticatedUserPayload["email_address"] as? String
            isWorkspaceAuthenticated = true

            let workspaceContext = try await resolveWorkspaceContext(accessToken: accessToken)
            persistBackendSession(
                accessToken: accessToken,
                workspaceID: workspaceContext.workspaceID
            )
            workspaceDisplayName = workspaceContext.workspaceDisplayName
            await loadWorkspaceDirectory(parentEntryPath: "/")
        } catch {
            if isUnauthorizedBackendError(error) {
                clearBackendSession()
            }
            clearWorkspacePanelSessionState()
            workspaceErrorMessage = error.localizedDescription
        }
    }

    func loginWorkspaceUser(
        emailAddress: String,
        password: String
    ) async {
        await authenticateWorkspaceUser(
            path: "/auth/login",
            emailAddress: emailAddress,
            password: password
        )
    }

    func registerWorkspaceUser(
        emailAddress: String,
        password: String
    ) async {
        await authenticateWorkspaceUser(
            path: "/auth/register",
            emailAddress: emailAddress,
            password: password
        )
    }

    func logoutWorkspaceUser() async {
        if let accessToken = backendAgentAuthToken {
            _ = try? await sendBackendRequest(
                path: "/auth/logout",
                method: "POST",
                accessToken: accessToken,
                jsonBody: nil
            )
        }
        clearBackendSession()
        clearWorkspacePanelSessionState()
    }

    func startNewWorkspaceAgentSession() {
        // Reset backend conversation memory so the next `/agent/runs` call
        // starts from a clean context while keeping auth/workspace selection.
        backendAgentConversationMessages = []
        backendAgentSessionID = nil
        UserDefaults.standard.removeObject(forKey: Self.backendAgentSessionIDUserDefaultsKey)
        workspaceErrorMessage = nil
        workspaceStatusMessage = "Started a new session."
    }

    func openWorkspaceParentDirectory() {
        let parentDirectoryPath = parentWorkspaceEntryPath(for: workspaceCurrentDirectoryPath)
        Task {
            await loadWorkspaceDirectory(parentEntryPath: parentDirectoryPath)
        }
    }

    func openWorkspaceEntry(_ workspaceEntry: WorkspacePanelEntry) {
        Task {
            if workspaceEntry.isDirectory {
                await loadWorkspaceDirectory(parentEntryPath: workspaceEntry.entryPath)
            } else {
                await loadWorkspaceFilePreview(entryPath: workspaceEntry.entryPath)
            }
        }
    }

    func uploadWorkspaceFileSystemItems(_ selectedURLs: [URL]) async {
        workspaceErrorMessage = nil
        workspaceStatusMessage = nil
        selectedWorkspaceFilePath = nil
        selectedWorkspaceFileTextPreview = nil

        guard let accessToken = backendAgentAuthToken,
              let workspaceID = backendAgentWorkspaceID else {
            workspaceErrorMessage = "Sign in before uploading files."
            return
        }

        let uploadItems = collectWorkspaceUploadItems(
            from: selectedURLs,
            destinationDirectoryPath: workspaceCurrentDirectoryPath
        )
        guard !uploadItems.isEmpty else {
            workspaceStatusMessage = "No files selected."
            return
        }

        isWorkspaceUploading = true
        defer { isWorkspaceUploading = false }

        do {
            for (uploadIndex, workspaceUploadItem) in uploadItems.enumerated() {
                workspaceStatusMessage = "Uploading \(uploadIndex + 1)/\(uploadItems.count)…"
                try await uploadWorkspaceFile(
                    workspaceUploadItem: workspaceUploadItem,
                    workspaceID: workspaceID,
                    accessToken: accessToken
                )
            }
            workspaceStatusMessage = "Uploaded \(uploadItems.count) file(s)."
            await loadWorkspaceDirectory(parentEntryPath: workspaceCurrentDirectoryPath)
        } catch {
            workspaceErrorMessage = error.localizedDescription
        }
    }

    private func authenticateWorkspaceUser(
        path: String,
        emailAddress: String,
        password: String
    ) async {
        workspaceErrorMessage = nil
        workspaceStatusMessage = nil
        isWorkspaceLoading = true
        defer { isWorkspaceLoading = false }

        let normalizedEmailAddress = emailAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEmailAddress.isEmpty else {
            workspaceErrorMessage = "Email is required."
            return
        }

        do {
            let authPayload = try await sendBackendJSONRequest(
                path: path,
                method: "POST",
                accessToken: nil,
                jsonBody: [
                    "email_address": normalizedEmailAddress,
                    "password": password,
                ]
            )
            guard let accessToken = authPayload["access_token"] as? String else {
                throw NSError(
                    domain: "CompanionManager",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Authentication did not return access_token."]
                )
            }
            let authUserPayload = authPayload["user"] as? [String: Any]
            workspaceAuthenticatedUserEmailAddress = authUserPayload?["email_address"] as? String
            isWorkspaceAuthenticated = true

            let workspaceContext = try await resolveWorkspaceContext(accessToken: accessToken)
            persistBackendSession(
                accessToken: accessToken,
                workspaceID: workspaceContext.workspaceID
            )
            workspaceDisplayName = workspaceContext.workspaceDisplayName
            await loadWorkspaceDirectory(parentEntryPath: "/")
        } catch {
            if isUnauthorizedBackendError(error) {
                clearBackendSession()
                clearWorkspacePanelSessionState()
            }
            workspaceErrorMessage = error.localizedDescription
        }
    }

    private func resolveWorkspaceContext(
        accessToken: String
    ) async throws -> (workspaceID: String, workspaceDisplayName: String) {
        var workspacesPayload = try await sendBackendJSONArrayRequest(
            path: "/workspaces/",
            method: "GET",
            accessToken: accessToken
        )
        if workspacesPayload.isEmpty {
            let createdWorkspacePayload = try await sendBackendJSONRequest(
                path: "/workspaces/",
                method: "POST",
                accessToken: accessToken,
                jsonBody: [
                    "display_name": "My Workspace",
                    "workspace_metadata": [
                        "created_from_companion_panel": true,
                    ],
                ]
            )
            workspacesPayload = [createdWorkspacePayload]
        }

        guard let firstWorkspace = workspacesPayload.first,
              let workspaceID = firstWorkspace["id"] as? String else {
            throw NSError(
                domain: "CompanionManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No accessible workspace was found."]
            )
        }
        let workspaceDisplayName = (firstWorkspace["display_name"] as? String) ?? "My Workspace"
        return (workspaceID, workspaceDisplayName)
    }

    private func loadWorkspaceDirectory(parentEntryPath: String) async {
        workspaceErrorMessage = nil
        isWorkspaceLoading = true
        defer { isWorkspaceLoading = false }

        guard let accessToken = backendAgentAuthToken,
              let workspaceID = backendAgentWorkspaceID else {
            clearWorkspacePanelSessionState()
            return
        }

        do {
            let encodedParentEntryPath = parentEntryPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "/"
            let entriesResponseObject = try await sendBackendRequest(
                path: "/workspaces/\(workspaceID)/entries?parent_entry_path=\(encodedParentEntryPath)",
                method: "GET",
                accessToken: accessToken,
                jsonBody: nil
            )
            guard let entriesPayload = entriesResponseObject as? [String: Any] else {
                throw NSError(
                    domain: "CompanionManager",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected object response for workspace entries."]
                )
            }
            let entryPayloads = entriesPayload["entries"] as? [[String: Any]] ?? []
            workspaceEntries = entryPayloads.compactMap { workspaceEntryPayload in
                guard let entryPath = workspaceEntryPayload["entry_path"] as? String,
                      let entryName = workspaceEntryPayload["entry_name"] as? String,
                      let entryType = workspaceEntryPayload["entry_type"] as? String else {
                    return nil
                }
                return WorkspacePanelEntry(
                    id: entryPath,
                    entryName: entryName,
                    entryPath: entryPath,
                    entryType: entryType,
                    contentType: workspaceEntryPayload["content_type"] as? String,
                    sizeBytes: workspaceEntryPayload["size_bytes"] as? Int
                )
            }
            workspaceCurrentDirectoryPath = (entriesPayload["parent_entry_path"] as? String) ?? parentEntryPath
            selectedWorkspaceFilePath = nil
            selectedWorkspaceFileTextPreview = nil
        } catch {
            if isUnauthorizedBackendError(error) {
                clearBackendSession()
                clearWorkspacePanelSessionState()
            }
            workspaceErrorMessage = error.localizedDescription
        }
    }

    private func loadWorkspaceFilePreview(entryPath: String) async {
        workspaceErrorMessage = nil
        isWorkspaceLoading = true
        defer { isWorkspaceLoading = false }

        guard let accessToken = backendAgentAuthToken,
              let workspaceID = backendAgentWorkspaceID else {
            clearWorkspacePanelSessionState()
            return
        }

        do {
            let encodedEntryPath = entryPath.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? entryPath
            let workspaceFileResponseObject = try await sendBackendRequest(
                path: "/workspaces/\(workspaceID)/entries/read?entry_path=\(encodedEntryPath)",
                method: "GET",
                accessToken: accessToken,
                jsonBody: nil
            )
            guard let workspaceFilePayload = workspaceFileResponseObject as? [String: Any] else {
                throw NSError(
                    domain: "CompanionManager",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Expected object response for workspace file read."]
                )
            }
            selectedWorkspaceFilePath = entryPath
            let hasBinaryContent = workspaceFilePayload["has_binary_content"] as? Bool ?? false
            let textContent = workspaceFilePayload["text_content"] as? String
            if let textContent, !textContent.isEmpty {
                selectedWorkspaceFileTextPreview = textContent
            } else if hasBinaryContent {
                selectedWorkspaceFileTextPreview = "[Binary content]"
            } else {
                selectedWorkspaceFileTextPreview = ""
            }
        } catch {
            if isUnauthorizedBackendError(error) {
                clearBackendSession()
                clearWorkspacePanelSessionState()
            }
            workspaceErrorMessage = error.localizedDescription
        }
    }

    private struct WorkspaceUploadItem {
        let fileURL: URL
        let entryPath: String
    }

    private func collectWorkspaceUploadItems(
        from selectedURLs: [URL],
        destinationDirectoryPath: String
    ) -> [WorkspaceUploadItem] {
        let fileManager = FileManager.default
        var workspaceUploadItems: [WorkspaceUploadItem] = []

        for selectedURL in selectedURLs {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: selectedURL.path, isDirectory: &isDirectory) else {
                continue
            }

            if isDirectory.boolValue {
                guard let fileEnumerator = fileManager.enumerator(
                    at: selectedURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    continue
                }

                for case let descendantURL as URL in fileEnumerator {
                    let resourceValues = try? descendantURL.resourceValues(forKeys: [.isRegularFileKey])
                    guard resourceValues?.isRegularFile == true else {
                        continue
                    }
                    let relativePath = descendantURL.path.replacingOccurrences(
                        of: selectedURL.path + "/",
                        with: ""
                    )
                    let uploadPath = normalizeWorkspaceEntryPathForUpload(
                        workspacePathByAppending(
                            destinationDirectoryPath,
                            relativePath: selectedURL.lastPathComponent + "/" + relativePath
                        )
                    )
                    workspaceUploadItems.append(
                        WorkspaceUploadItem(fileURL: descendantURL, entryPath: uploadPath)
                    )
                }
            } else {
                let uploadPath = normalizeWorkspaceEntryPathForUpload(
                    workspacePathByAppending(
                        destinationDirectoryPath,
                        relativePath: selectedURL.lastPathComponent
                    )
                )
                workspaceUploadItems.append(
                    WorkspaceUploadItem(fileURL: selectedURL, entryPath: uploadPath)
                )
            }
        }

        return workspaceUploadItems.sorted { leftWorkspaceUploadItem, rightWorkspaceUploadItem in
            leftWorkspaceUploadItem.entryPath < rightWorkspaceUploadItem.entryPath
        }
    }

    private func uploadWorkspaceFile(
        workspaceUploadItem: WorkspaceUploadItem,
        workspaceID: String,
        accessToken: String
    ) async throws {
        let fileData = try Data(contentsOf: workspaceUploadItem.fileURL)
        let multipartBoundary = "Boundary-\(UUID().uuidString)"
        let fileName = workspaceUploadItem.fileURL.lastPathComponent
        let mimeType = UTType(filenameExtension: workspaceUploadItem.fileURL.pathExtension)?
            .preferredMIMEType ?? "application/octet-stream"

        var multipartBody = Data()
        multipartBody.appendMultipartFormField(
            named: "entry_path",
            value: workspaceUploadItem.entryPath,
            usingBoundary: multipartBoundary
        )
        multipartBody.appendMultipartFileField(
            named: "file",
            filename: fileName,
            mimeType: mimeType,
            fileData: fileData,
            usingBoundary: multipartBoundary
        )
        multipartBody.appendString("--\(multipartBoundary)--\r\n")

        _ = try await sendBackendMultipartRequest(
            path: "/workspaces/\(workspaceID)/entries/upload",
            method: "POST",
            accessToken: accessToken,
            contentTypeHeader: "multipart/form-data; boundary=\(multipartBoundary)",
            bodyData: multipartBody
        )
    }

    private func persistBackendSession(
        accessToken: String,
        workspaceID: String
    ) {
        if backendAgentWorkspaceID != workspaceID {
            backendAgentSessionID = nil
            backendAgentConversationMessages = []
            UserDefaults.standard.removeObject(forKey: Self.backendAgentSessionIDUserDefaultsKey)
        }
        backendAgentAuthToken = accessToken
        backendAgentWorkspaceID = workspaceID
        UserDefaults.standard.set(accessToken, forKey: Self.backendAgentAuthTokenUserDefaultsKey)
        UserDefaults.standard.set(workspaceID, forKey: Self.backendAgentWorkspaceIDUserDefaultsKey)
    }

    private func clearBackendSession() {
        backendAgentAuthToken = nil
        backendAgentWorkspaceID = nil
        backendAgentSessionID = nil
        cachedBackendAgentTools = nil
        UserDefaults.standard.removeObject(forKey: Self.backendAgentAuthTokenUserDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.backendAgentWorkspaceIDUserDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.backendAgentSessionIDUserDefaultsKey)
    }

    private func clearWorkspacePanelSessionState() {
        isWorkspaceAuthenticated = false
        workspaceAuthenticatedUserEmailAddress = nil
        workspaceDisplayName = nil
        workspaceCurrentDirectoryPath = "/"
        workspaceEntries = []
        selectedWorkspaceFilePath = nil
        selectedWorkspaceFileTextPreview = nil
        workspaceStatusMessage = nil
        workspaceErrorMessage = nil
    }

    private func isUnauthorizedBackendError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.code == 401 || nsError.code == 403
    }

    private func parentWorkspaceEntryPath(for entryPath: String) -> String {
        let normalizedEntryPath = normalizeWorkspaceEntryPathForUpload(entryPath)
        if normalizedEntryPath == "/" {
            return "/"
        }
        let pathComponents = normalizedEntryPath
            .split(separator: "/")
            .map(String.init)
        guard pathComponents.count > 1 else {
            return "/"
        }
        return "/" + pathComponents.dropLast().joined(separator: "/")
    }

    private func normalizeWorkspaceEntryPathForUpload(_ path: String) -> String {
        let pathWithForwardSlashes = path.replacingOccurrences(of: "\\", with: "/")
        let pathComponents = pathWithForwardSlashes
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
        if pathComponents.isEmpty {
            return "/"
        }
        return "/" + pathComponents.joined(separator: "/")
    }

    private func workspacePathByAppending(
        _ directoryPath: String,
        relativePath: String
    ) -> String {
        let normalizedDirectoryPath = normalizeWorkspaceEntryPathForUpload(directoryPath)
        if normalizedDirectoryPath == "/" {
            return "/" + relativePath
        }
        return normalizedDirectoryPath + "/" + relativePath
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you are Deb, a helpful assistant with access to the user's screen.
    keep responses concise and practical.
    when visual guidance helps, call `companion.point` with screenshot pixel coordinates.
    when spoken output helps, call `companion.speak` with natural spoken text.
    for workspace file operations, use only `workspace.run_bash` and `workspace.search_toc`.
    default to working_directory `/` unless the user explicitly names a subfolder.
    use `workspace.run_bash` only for cheap read-only commands: `pwd`, `ls`, `find`, `cat`, `grep`, and `rg`.
    keep `workspace.run_bash` commands simple. avoid python, heredocs, pipes, subshells, long scripts, and write operations unless the user explicitly asks for a file change.
    important: `workspace.search_toc` only returns TOC heading matches; it is not page-text verification.
    if the user asks for a definition, formula, proof, or any exact statement, do this workflow:
    1) call `workspace.search_toc` to get candidate bundles and page_start/page_end.
    2) read actual content with `workspace.run_bash` + `cat` from absolute page paths like `/...__ingested/pages/page-0017.md`.
    3) if needed, read nearby pages (`page_start-1`, `page_start`, `page_start+1`) before answering.
    do not claim a page says something unless you actually read that page content with `cat`.
    do not use `cd`; pass absolute paths directly to `ls`, `find`, `cat`, `grep`, and `rg`.
    """

    // MARK: - AI Response Pipeline

    /// Captures screenshots, sends transcript + images to `/agent/runs`,
    /// executes `companion.*` tools locally, and lets backend execute
    /// workspace tools.
    private func sendTranscriptToAgentWithScreenshots(transcript: String) {
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                guard !Task.isCancelled else { return }
                let backendAgentSessionContext = try await ensureBackendAgentSessionContext()
                let backendAgentTools = try await getBackendAgentTools(
                    accessToken: backendAgentSessionContext.accessToken
                )
                var conversationMessages = backendAgentConversationMessages
                conversationMessages.append(
                    buildBackendAgentUserMessage(
                        transcript: transcript,
                        screenCaptures: screenCaptures
                    )
                )

                var finalOutputText = ""
                var didSpeakViaTool = false
                for _ in 0..<8 {
                    guard !Task.isCancelled else { return }
                    let runResponsePayload = try await createBackendAgentRun(
                        accessToken: backendAgentSessionContext.accessToken,
                        messages: conversationMessages,
                        tools: backendAgentTools,
                        workspaceID: backendAgentSessionContext.workspaceID
                    )
                    guard let responseMessages = runResponsePayload["messages"] as? [[String: Any]] else {
                        throw NSError(
                            domain: "CompanionManager",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Agent response did not include messages."]
                        )
                    }
                    conversationMessages = responseMessages
                    if let responseAgentSessionID = runResponsePayload["agent_session_id"] as? String,
                       !responseAgentSessionID.isEmpty {
                        backendAgentSessionID = responseAgentSessionID
                        UserDefaults.standard.set(
                            responseAgentSessionID,
                            forKey: Self.backendAgentSessionIDUserDefaultsKey
                        )
                    }
                    finalOutputText = runResponsePayload["final_output_text"] as? String ?? ""
                    let responseStatus = runResponsePayload["status"] as? String ?? "completed"

                    if responseStatus == "awaiting_client_tools" {
                        let pendingCompanionToolCalls = findPendingCompanionToolCalls(
                            messages: conversationMessages
                        )
                        if pendingCompanionToolCalls.isEmpty {
                            break
                        }
                        let companionToolOutcome = try await executeCompanionToolCalls(
                            pendingCompanionToolCalls,
                            screenCaptures: screenCaptures
                        )
                        didSpeakViaTool = didSpeakViaTool || companionToolOutcome.didSpeak
                        conversationMessages.append(contentsOf: companionToolOutcome.toolMessages)
                        continue
                    }
                    break
                }

                backendAgentConversationMessages = trimBackendAgentConversationMessages(conversationMessages)
                DebAnalytics.trackAIResponseReceived(response: finalOutputText)

                if !didSpeakViaTool && !finalOutputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await elevenLabsTTSClient.speakText(finalOutputText)
                        voiceState = .responding
                    } catch {
                        DebAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ ElevenLabs TTS error: \(error)")
                        speakCreditsErrorFallback()
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                DebAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                speakCreditsErrorFallback()
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    private struct BackendAgentSessionContext {
        let accessToken: String
        let workspaceID: String
    }

    private struct CompanionToolOutcome {
        let toolMessages: [[String: Any]]
        let didSpeak: Bool
    }

    private func ensureBackendAgentSessionContext() async throws -> BackendAgentSessionContext {
        if let existingAccessToken = backendAgentAuthToken,
           let existingWorkspaceID = backendAgentWorkspaceID {
            return BackendAgentSessionContext(
                accessToken: existingAccessToken,
                workspaceID: existingWorkspaceID
            )
        }

        let generatedEmailAddress = "deb-macos-\(UUID().uuidString.lowercased())@local.deb"
        let generatedPassword = UUID().uuidString + UUID().uuidString
        let registrationPayload = try await sendBackendJSONRequest(
            path: "/auth/register",
            method: "POST",
            accessToken: nil,
            jsonBody: [
                "email_address": generatedEmailAddress,
                "password": generatedPassword,
            ]
        )
        guard let accessToken = registrationPayload["access_token"] as? String else {
            throw NSError(
                domain: "CompanionManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Registration did not return access_token."]
            )
        }
        let workspacesPayload = try await sendBackendJSONArrayRequest(
            path: "/workspaces/",
            method: "GET",
            accessToken: accessToken
        )
        guard let firstWorkspace = workspacesPayload.first,
              let workspaceID = firstWorkspace["id"] as? String else {
            throw NSError(
                domain: "CompanionManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No workspace returned after registration."]
            )
        }

        persistBackendSession(
            accessToken: accessToken,
            workspaceID: workspaceID
        )
        return BackendAgentSessionContext(accessToken: accessToken, workspaceID: workspaceID)
    }

    private func getBackendAgentTools(accessToken: String) async throws -> [[String: Any]] {
        if let cachedBackendAgentTools {
            return filterAllowedBackendAgentTools(cachedBackendAgentTools)
        }
        let toolsPayload = try await sendBackendJSONArrayRequest(
            path: "/agent/tools",
            method: "GET",
            accessToken: accessToken
        )
        let filteredBackendAgentTools = filterAllowedBackendAgentTools(toolsPayload)
        cachedBackendAgentTools = filteredBackendAgentTools
        return filteredBackendAgentTools
    }

    private func filterAllowedBackendAgentTools(
        _ toolsPayload: [[String: Any]]
    ) -> [[String: Any]] {
        let allowedToolNames: Set<String> = [
            "companion.point",
            "companion.speak",
            "workspace.run_bash",
            "workspace.search_toc",
        ]
        return toolsPayload.filter { toolPayload in
            guard let toolName = toolPayload["name"] as? String else {
                return false
            }
            return allowedToolNames.contains(toolName)
        }
    }

    private func buildBackendAgentUserMessage(
        transcript: String,
        screenCaptures: [CompanionScreenCapture]
    ) -> [String: Any] {
        let imagePayloads: [[String: Any]] = screenCaptures.map { screenCapture in
            [
                "image_base64": screenCapture.imageData.base64EncodedString(),
                "mime_type": "image/jpeg",
                "label": screenCapture.label,
                "pixel_width": screenCapture.screenshotWidthInPixels,
                "pixel_height": screenCapture.screenshotHeightInPixels,
                "is_primary_focus": screenCapture.isCursorScreen,
            ]
        }
        return [
            "role": "user",
            "content": transcript,
            "images": imagePayloads,
        ]
    }

    private func createBackendAgentRun(
        accessToken: String,
        messages: [[String: Any]],
        tools: [[String: Any]],
        workspaceID: String
    ) async throws -> [String: Any] {
        var runRequestPayload: [String: Any] = [
            "provider": "openai_responses",
            "workspace_id": workspaceID,
            "system_message": Self.companionVoiceResponseSystemPrompt
                + "\nworkspace tool context: use `workspace.search_toc` to narrow to section/page candidates, then use `workspace.run_bash` + `cat /...__ingested/pages/page-XXXX.md` to verify real page text before answering. always pass workspace_id `\(workspaceID)`.",
            "messages": messages,
            "tools": tools,
            "tool_choice": "auto",
            "max_iterations": 8,
        ]
        if let backendAgentSessionID, !backendAgentSessionID.isEmpty {
            runRequestPayload["agent_session_id"] = backendAgentSessionID
        }

        return try await sendBackendJSONRequest(
            path: "/agent/runs",
            method: "POST",
            accessToken: accessToken,
            jsonBody: runRequestPayload
        )
    }

    private func findPendingCompanionToolCalls(messages: [[String: Any]]) -> [[String: Any]] {
        var completedToolCallIDs = Set<String>()
        for message in messages {
            guard let messageRole = message["role"] as? String,
                  messageRole == "tool",
                  let toolCallID = message["tool_call_id"] as? String else {
                continue
            }
            completedToolCallIDs.insert(toolCallID)
        }

        var pendingCompanionToolCalls: [[String: Any]] = []
        for message in messages {
            guard let messageRole = message["role"] as? String,
                  messageRole == "assistant",
                  let assistantToolCalls = message["tool_calls"] as? [[String: Any]] else {
                continue
            }
            for assistantToolCall in assistantToolCalls {
                guard let toolCallID = assistantToolCall["id"] as? String,
                      let toolName = assistantToolCall["name"] as? String,
                      toolName.hasPrefix("companion."),
                      !completedToolCallIDs.contains(toolCallID) else {
                    continue
                }
                pendingCompanionToolCalls.append(assistantToolCall)
            }
        }

        return pendingCompanionToolCalls
    }

    private func executeCompanionToolCalls(
        _ companionToolCalls: [[String: Any]],
        screenCaptures: [CompanionScreenCapture]
    ) async throws -> CompanionToolOutcome {
        var toolMessages: [[String: Any]] = []
        var didSpeak = false

        for companionToolCall in companionToolCalls {
            guard let toolCallID = companionToolCall["id"] as? String,
                  let toolName = companionToolCall["name"] as? String else {
                continue
            }
            let argumentsJSON = companionToolCall["arguments_json"] as? String ?? "{}"
            let argumentsData = argumentsJSON.data(using: .utf8) ?? Data("{}".utf8)
            let argumentsPayload = (
                (try? JSONSerialization.jsonObject(with: argumentsData, options: []))
                as? [String: Any]
            ) ?? [:]

            var toolOutput: [String: Any] = ["status": "ok"]
            if toolName == "companion.point" {
                let pointX = (argumentsPayload["x"] as? NSNumber)?.doubleValue ?? 0
                let pointY = (argumentsPayload["y"] as? NSNumber)?.doubleValue ?? 0
                let screenNumber = (argumentsPayload["screen_number"] as? NSNumber)?.intValue ?? 1
                let pointLabel = (argumentsPayload["label"] as? String) ?? "element"
                applyPointingTarget(
                    x: pointX,
                    y: pointY,
                    label: pointLabel,
                    screenNumber: screenNumber,
                    screenCaptures: screenCaptures
                )
                toolOutput = [
                    "status": "pointed",
                    "x": Int(pointX),
                    "y": Int(pointY),
                    "screen_number": screenNumber,
                    "label": pointLabel,
                ]
            } else if toolName == "companion.speak" {
                let speechText = (argumentsPayload["text"] as? String) ?? ""
                if !speechText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try await elevenLabsTTSClient.speakText(speechText)
                    voiceState = .responding
                    didSpeak = true
                }
                toolOutput = [
                    "status": "spoken",
                    "text": speechText,
                ]
            } else {
                toolOutput = [
                    "status": "unsupported_client_tool",
                    "tool_name": toolName,
                ]
            }

            let toolOutputData = try JSONSerialization.data(withJSONObject: toolOutput)
            let toolOutputText = String(data: toolOutputData, encoding: .utf8) ?? "{}"
            toolMessages.append(
                [
                    "role": "tool",
                    "tool_call_id": toolCallID,
                    "name": toolName,
                    "content": toolOutputText,
                ]
            )
        }

        return CompanionToolOutcome(toolMessages: toolMessages, didSpeak: didSpeak)
    }

    private func applyPointingTarget(
        x: Double,
        y: Double,
        label: String,
        screenNumber: Int,
        screenCaptures: [CompanionScreenCapture]
    ) {
        guard !screenCaptures.isEmpty else { return }
        let targetScreenIndex = max(0, min(screenCaptures.count - 1, screenNumber - 1))
        let targetScreenCapture = screenCaptures[targetScreenIndex]
        let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
        let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
        let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
        let displayFrame = targetScreenCapture.displayFrame

        let clampedX = max(0, min(CGFloat(x), screenshotWidth))
        let clampedY = max(0, min(CGFloat(y), screenshotHeight))
        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)
        let appKitY = displayHeight - displayLocalY
        let globalLocation = CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )

        voiceState = .idle
        detectedElementScreenLocation = globalLocation
        detectedElementDisplayFrame = displayFrame
        detectedElementBubbleText = nil
        DebAnalytics.trackElementPointed(elementLabel: label)
        print("🎯 Agent point tool: (\(Int(x)), \(Int(y))) → \"\(label)\" on screen \(screenNumber)")
    }

    private func trimBackendAgentConversationMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        let maximumRetainedMessages = 40
        if messages.count <= maximumRetainedMessages {
            return messages
        }
        return Array(messages.suffix(maximumRetainedMessages))
    }

    private func sendBackendJSONRequest(
        path: String,
        method: String,
        accessToken: String?,
        jsonBody: [String: Any]
    ) async throws -> [String: Any] {
        let responseObject = try await sendBackendRequest(
            path: path,
            method: method,
            accessToken: accessToken,
            jsonBody: jsonBody
        )
        guard let responsePayload = responseObject as? [String: Any] else {
            throw NSError(
                domain: "CompanionManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Expected JSON object response for \(path)."]
            )
        }
        return responsePayload
    }

    private func sendBackendJSONArrayRequest(
        path: String,
        method: String,
        accessToken: String?
    ) async throws -> [[String: Any]] {
        let responseObject = try await sendBackendRequest(
            path: path,
            method: method,
            accessToken: accessToken,
            jsonBody: nil
        )
        guard let responsePayload = responseObject as? [[String: Any]] else {
            throw NSError(
                domain: "CompanionManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Expected JSON array response for \(path)."]
            )
        }
        return responsePayload
    }

    private func sendBackendRequest(
        path: String,
        method: String,
        accessToken: String?,
        jsonBody: [String: Any]?
    ) async throws -> Any {
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard let requestURL = URL(string: AppBundleConfiguration.backendBaseURL() + normalizedPath) else {
            throw NSError(
                domain: "CompanionManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid backend URL for path \(path)."]
            )
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let jsonBody {
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }

        let (responseData, response) = try await backendAgentSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "CompanionManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response from backend."]
            )
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: responseData, encoding: .utf8) ?? "Unknown backend error."
            throw NSError(
                domain: "CompanionManager",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Backend request failed: \(errorText)"]
            )
        }
        return try JSONSerialization.jsonObject(with: responseData, options: [])
    }

    private func sendBackendMultipartRequest(
        path: String,
        method: String,
        accessToken: String?,
        contentTypeHeader: String,
        bodyData: Data
    ) async throws -> Any {
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard let requestURL = URL(string: AppBundleConfiguration.backendBaseURL() + normalizedPath) else {
            throw NSError(
                domain: "CompanionManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid backend URL for path \(path)."]
            )
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.setValue(contentTypeHeader, forHTTPHeaderField: "Content-Type")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = bodyData

        let (responseData, response) = try await backendAgentSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "CompanionManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response from backend."]
            )
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorText = String(data: responseData, encoding: .utf8) ?? "Unknown backend error."
            throw NSError(
                domain: "CompanionManager",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Backend request failed: \(errorText)"]
            )
        }
        return try JSONSerialization.jsonObject(with: responseData, options: [])
    }

    /// If the cursor is in transient mode (user toggled "Show Deb" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isDebCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
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
        }
    }

    /// Speaks a hardcoded error message using macOS system TTS when API
    /// credits run out. Uses NSSpeechSynthesizer so it works even when
    /// ElevenLabs is down.
    private func speakCreditsErrorFallback() {
        let utterance = "I'm all out of credits. Please DM Farza and tell him to bring Deb back to life."
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
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
        // Deb flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            DebAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            DebAnalytics.trackOnboardingVideoCompleted()
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
    you're deb, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

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
