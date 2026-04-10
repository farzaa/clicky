//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AppKit
import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: NSObject, ObservableObject, NSSpeechSynthesizerDelegate {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

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
    private let fallbackSpeechSynthesizer = NSSpeechSynthesizer()
    private var currentFallbackSpeechIdentifier: UUID?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    let companionResponseOverlayManager = CompanionResponseOverlayManager()
    let delegationRepoPickerOverlayManager = DelegationRepoPickerOverlayManager()
    let delegationLogSidebarManager = DelegationLogSidebarManager()
    let workspaceInventoryStore = WorkspaceInventoryStore()
    let delegationAgentRuntimeRegistry = DelegationAgentRuntimeRegistry()
    @Published private(set) var currentActionIntent: ClickyActionIntent = .reply
    @Published private(set) var isAwaitingDelegationWorkspaceSelection = false
    @Published private(set) var pendingDelegationRequest: ClickyDelegationRequest?
    @Published private(set) var selectedDelegationWorkspace: WorkspaceInventoryStore.WorkspaceRecord?
    @Published private(set) var selectedDelegationRuntimeID: DelegationAgentRuntimeID?

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary.
    private static let workerBaseURL =
        AppBundleConfiguration.stringValue(forKey: "ClickyWorkerBaseURL") ??
        "https://your-worker-name.your-subdomain.workers.dev"

    /// Optional onboarding video source. When missing, onboarding skips the
    /// video/demo segment and goes straight to the voice prompt.
    private static var onboardingVideoURL: URL? {
        guard let onboardingVideoURLString = AppBundleConfiguration.stringValue(forKey: "OnboardingVideoURL") else {
            return nil
        }

        return URL(string: onboardingVideoURLString)
    }

    private lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: selectedModel)
    }()

    private lazy var actionIntentClassifierAPI: ClaudeAPI = {
        return ClaudeAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: "claude-sonnet-4-0")
    }()

    private lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient(proxyURL: "\(Self.workerBaseURL)/tts")
    }()

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    private struct ActionIntentClassificationPayload: Decodable {
        let intent: ClickyActionIntent
    }

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?
    /// Separate task for markdown transcript generation so it can stream into
    /// the cursor-adjacent card while the spoken response continues normally.
    private var currentMarkdownTranscriptTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var stopSpeechPlaybackShortcutCancellable: AnyCancellable?
    private var markdownTranscriptCopyShortcutCancellable: AnyCancellable?
    private var pickerNavigationCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?
    private var latestGeneratedMarkdownTranscriptText: String?
    private(set) var pendingDelegationScreenCaptures: [CompanionScreenCapture] = []
    private let delegationAgentLauncher = DelegationAgentLauncher()

    /// A delegation that has been accepted by Flowee and sits in a
    /// per-workspace FIFO queue waiting to be launched. The matching
    /// sidebar session already exists in the "queued" state — when
    /// this entry is popped off the queue we promote that session
    /// and call the launcher.
    private struct EnqueuedDelegation {
        let sidebarSessionID: UUID
        let request: ClickyDelegationRequest
        let workspace: WorkspaceInventoryStore.WorkspaceRecord
        let runtime: InstalledDelegationAgentRuntime
    }

    /// One FIFO queue per workspace, keyed by workspace ID. Only the
    /// entries after the first one are actually "waiting" — the head
    /// of the queue (if any) is the one whose process is currently
    /// running, mirrored by `activelyRunningDelegationSidebarSessionByWorkspaceID`.
    private var delegationQueuesByWorkspaceID: [UUID: [EnqueuedDelegation]] = [:]

    /// Maps a workspace ID to the sidebar session ID whose agent
    /// process is currently running for that workspace. `nil` means
    /// no delegation is running in that workspace right now (any
    /// queued delegations will be promoted as soon as they arrive).
    private var activelyRunningDelegationSidebarSessionByWorkspaceID: [UUID: UUID] = [:]

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

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
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
        fallbackSpeechSynthesizer.delegate = self
        globalPushToTalkShortcutMonitor.shouldConsumeEscapeKey = { [weak self] in
            guard let self else { return false }
            return self.elevenLabsTTSClient.isPlaying || self.fallbackSpeechSynthesizer.isSpeaking
        }
        globalPushToTalkShortcutMonitor.shouldConsumeMarkdownTranscriptCopyShortcut = { [weak self] in
            guard let self else { return false }
            return self.latestGeneratedMarkdownTranscriptText != nil
        }
        globalPushToTalkShortcutMonitor.shouldConsumePickerNavigationInput = { [weak self] in
            guard let self else { return false }
            return self.delegationRepoPickerOverlayManager.isVisible
        }
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindStopSpeechPlaybackShortcut()
        bindMarkdownTranscriptCopyShortcut()
        bindPickerNavigationShortcut()
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI
        Task {
            await buddyDictationManager.prewarmTranscriptionProviderIfNeeded()
        }

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
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
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

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
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
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
            print("⚠️ Clicky: ff.mp3 not found in bundle")
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
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
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
        globalPushToTalkShortcutMonitor.shouldConsumeEscapeKey = nil
        globalPushToTalkShortcutMonitor.shouldConsumeMarkdownTranscriptCopyShortcut = nil
        globalPushToTalkShortcutMonitor.shouldConsumePickerNavigationInput = nil
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        companionResponseOverlayManager.hideMarkdownTranscriptOverlay()
        cancelPendingDelegationFlow()
        delegationLogSidebarManager.hideAllSessions()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentMarkdownTranscriptTask?.cancel()
        currentResponseTask = nil
        currentMarkdownTranscriptTask = nil
        shortcutTransitionCancellable?.cancel()
        stopSpeechPlaybackShortcutCancellable?.cancel()
        markdownTranscriptCopyShortcutCancellable?.cancel()
        pickerNavigationCancellable?.cancel()
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
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
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
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
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

    private func bindStopSpeechPlaybackShortcut() {
        stopSpeechPlaybackShortcutCancellable = globalPushToTalkShortcutMonitor
            .stopSpeechPlaybackPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleStopSpeechPlaybackShortcut()
            }
    }

    private func bindMarkdownTranscriptCopyShortcut() {
        markdownTranscriptCopyShortcutCancellable = globalPushToTalkShortcutMonitor
            .markdownTranscriptCopyPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.handleMarkdownTranscriptCopyShortcut()
            }
    }

    private func bindPickerNavigationShortcut() {
        pickerNavigationCancellable = globalPushToTalkShortcutMonitor
            .pickerNavigationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handlePickerNavigationEvent(event)
            }
    }

    private func handleStopSpeechPlaybackShortcut() {
        guard elevenLabsTTSClient.isPlaying || fallbackSpeechSynthesizer.isSpeaking else { return }
        print("🔊 Stop speech shortcut pressed (escape)")
        stopAllSpeechPlayback()
        voiceState = .idle
        scheduleTransientHideIfNeeded()
    }

    private func handleMarkdownTranscriptCopyShortcut() {
        guard let latestGeneratedMarkdownTranscriptText else { return }
        print("📝 Markdown transcript copy shortcut pressed")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(latestGeneratedMarkdownTranscriptText, forType: .string)
        self.latestGeneratedMarkdownTranscriptText = nil
        companionResponseOverlayManager.showCopiedMarkdownTranscriptStatus()
    }

    private func handlePickerNavigationEvent(_ event: GlobalPushToTalkShortcutMonitor.PickerNavigationEvent) {
        guard delegationRepoPickerOverlayManager.isVisible else { return }

        switch event {
        case .moveUp:
            delegationRepoPickerOverlayManager.moveSelectionUp()
        case .moveDown:
            delegationRepoPickerOverlayManager.moveSelectionDown()
        case .moveLeft:
            delegationRepoPickerOverlayManager.moveRuntimeLeft()
        case .moveRight:
            delegationRepoPickerOverlayManager.moveRuntimeRight()
        case .confirmSelection:
            delegationRepoPickerOverlayManager.confirmSelection()
        case .cancelSelection:
            delegationRepoPickerOverlayManager.cancelSelection()
        }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard latestGeneratedMarkdownTranscriptText == nil else { return }
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            currentMarkdownTranscriptTask?.cancel()
            currentMarkdownTranscriptTask = nil
            latestGeneratedMarkdownTranscriptText = nil
            cancelPendingDelegationFlow()
            stopAllSpeechPlayback()
            clearDetectedElementLocation()
            companionResponseOverlayManager.hideMarkdownTranscriptOverlay()

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
    

            ClickyAnalytics.trackPushToTalkStarted()

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
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're flowee, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

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

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    private static let markdownTranscriptRequestKeywords = [
        "markdown",
        ".md",
        "text file",
        "transcript",
        "whiteboard",
        "ascii",
        "diagram"
    ]

    private static let companionMarkdownTranscriptSystemPrompt = """
    you're flowee generating a markdown transcript from screenshot images. the user wants a text file version of what is visible, often for whiteboards, notes, sketches, or diagrams.

    rules:
    - return markdown only. no preamble, no explanation outside the markdown.
    - be objective and visual. describe what is actually visible, not what you assume was intended.
    - preserve uncertainty. if text is unclear, mark it as [unclear] instead of inventing it.
    - if the layout matters, include a fenced code block that uses plain ascii characters to show the structure diagrammatically.
    - keep text legible and useful for copying into docs. short sentences, clear headings.
    - if there are multiple screenshots, prioritize the one labeled "primary focus" and fold in relevant details from the others only when they clearly belong to the same content.
    - do not mention being an ai model or refer to the request itself.

    preferred structure:
    # Transcript
    ## Summary
    ## Diagram
    ## Visible Text
    ## Ambiguities

    for "Diagram", use ascii only inside a fenced code block when spatial relationships matter. if there is no meaningful layout to preserve, say "No strong spatial layout visible."
    """

    // MARK: - AI Response Pipeline
    private static let actionIntentClassificationSystemPrompt = """
    you're flowee's intent router.

    classify the user's request into exactly one of:
    - reply
    - draft
    - delegate

    definitions:
    - reply: the user mainly wants explanation, analysis, brainstorming, guidance, or an answer back.
    - draft: the user wants a written artifact prepared for them, such as a message, dm, email, summary, or write-up.
    - delegate: the user wants a coding agent or local code workspace to take action on a real implementation task, bug fix, change, or investigation.

    use both the transcript and the screenshot context.

    routing bias:
    - prefer delegate when the user's statement is instructive, imperative, or execution-oriented.
    - if the user is telling flowee to change, fix, build, investigate, implement, clean up, adjust, or make something happen in a real codebase, classify as delegate.
    - short commands should still be delegate when they are asking flowee to act, even if they are underspecified.
    - if the transcript reads like an instruction to do work now, classify as delegate.
    - prefer draft when the user wants communication prepared for someone else.
    - prefer reply when they mainly want advice, interpretation, brainstorming, or explanation.

    examples:
    - "fix this spacing issue" -> {"intent":"delegate"}
    - "do this work" -> {"intent":"delegate"}
    - "make this change" -> {"intent":"delegate"}
    - "handle this" -> {"intent":"delegate"}
    - "work on this" -> {"intent":"delegate"}
    - "take care of this bug" -> {"intent":"delegate"}
    - "spin up an agent and handle this" -> {"intent":"delegate"}
    - "make this match the design on screen" -> {"intent":"delegate"}
    - "investigate why this is broken and patch it" -> {"intent":"delegate"}
    - "draft a slack message to varun about this" -> {"intent":"draft"}
    - "write up what i'm seeing here" -> {"intent":"draft"}
    - "what is going wrong here?" -> {"intent":"reply"}
    - "help me think through this architecture" -> {"intent":"reply"}

    return strict json only in this shape:
    {"intent":"reply|draft|delegate"}
    """

    // System prompt for the semantic delegation branch-name generator.
    // The goal is a branch name a human developer would be comfortable
    // seeing in `git branch` and on GitHub — something like
    // `feature/dark-mode-settings` or `fix/login-button-spacing` — rather
    // than the mechanical `clicky-main-20260410-142153-9c33bd` smash the
    // launcher used to produce. The launcher automatically prefixes the
    // result with `flowee/` and handles disambiguation on collision, so
    // this prompt should NOT include `flowee/` in its output.
    private static let delegationBranchNameGenerationSystemPrompt = """
    you generate a short git branch name body from a developer's spoken request.

    rules:
    - output format exactly: type/short-kebab-case-description
    - type must be one of: feature, fix, chore, refactor, docs, test
    - description is 2 to 5 words, lowercase, hyphen-separated
    - total length between 8 and 60 characters
    - never include dates, timestamps, uuids, random suffixes, or author names
    - never include the word flowee or any namespace prefix
    - no quotes, no punctuation, no explanations, no leading or trailing whitespace
    - respond with only the branch name on a single line and nothing else

    examples:
    request: "fix the spacing issue on the login button"
    fix/login-button-spacing

    request: "add dark mode support to settings"
    feature/settings-dark-mode

    request: "remove all the unused imports in the api module"
    chore/remove-unused-api-imports

    request: "the api keeps timing out, figure out why and patch it"
    fix/api-timeout-investigation

    request: "refactor the auth flow to be async"
    refactor/async-auth-flow

    request: "document the delegation launcher architecture"
    docs/delegation-launcher-architecture
    """

    private static func shouldGenerateMarkdownTranscript(for transcript: String) -> Bool {
        let normalizedTranscript = transcript.lowercased()
        return markdownTranscriptRequestKeywords.contains { normalizedTranscript.contains($0) }
    }

    private func classifyActionIntent(
        transcript: String,
        labeledImages: [(data: Data, label: String)]
    ) async -> ClickyActionIntent {
        let classificationPrompt = """
        classify this request for flowee.

        transcript:
        \(transcript)

        screenshot context labels:
        \(labeledImages.map(\.label).joined(separator: " | "))
        """

        do {
            let (classificationResponseText, _) = try await actionIntentClassifierAPI.analyzeImage(
                images: labeledImages,
                systemPrompt: Self.actionIntentClassificationSystemPrompt,
                userPrompt: classificationPrompt
            )

            let resolvedIntent = extractActionIntent(from: classificationResponseText)
            print("🧭 Intent classifier raw response: \(classificationResponseText)")
            print("🧭 Intent classifier resolved: \(resolvedIntent.rawValue)")
            return resolvedIntent
        } catch {
            print("⚠️ Intent classifier failed: \(error)")
            return .reply
        }
    }

    /// Asks the lightweight classifier API to turn the user's spoken
    /// delegation request into a short, human-readable branch name body
    /// (e.g. `fix/login-button-spacing`). The result is passed to
    /// `DelegationAgentLauncher` as a hint — the launcher is responsible
    /// for adding the `flowee/` namespace prefix, validating the hint,
    /// and retrying with a numeric suffix on collision. Returns nil on
    /// any failure so the launcher cleanly falls back to its legacy
    /// timestamp-based branch name instead of blocking the delegation.
    private func generateSemanticBranchNameHint(
        fromTranscript transcript: String
    ) async -> String? {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return nil }

        let branchNameGenerationUserPrompt = """
        developer request:
        \(trimmedTranscript)
        """

        do {
            let (rawBranchNameResponse, _) = try await actionIntentClassifierAPI.analyzeImage(
                images: [],
                systemPrompt: Self.delegationBranchNameGenerationSystemPrompt,
                userPrompt: branchNameGenerationUserPrompt
            )

            let cleanedBranchNameResponse = rawBranchNameResponse
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // The model should respond with a single line. If it stuffs
            // an explanation on later lines, take only the first
            // non-empty line — the launcher's sanitizer will handle the
            // rest (character validation, length, collision retry).
            let firstNonEmptyLine = cleanedBranchNameResponse
                .split(whereSeparator: { $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first(where: { !$0.isEmpty })

            print("🌿 Branch-name generator raw response: \(cleanedBranchNameResponse)")
            if let firstNonEmptyLine, !firstNonEmptyLine.isEmpty {
                return firstNonEmptyLine
            }
            return nil
        } catch {
            print("⚠️ Branch-name generator failed: \(error)")
            return nil
        }
    }

    private func extractActionIntent(from classificationResponseText: String) -> ClickyActionIntent {
        let cleanedClassificationResponseText = classificationResponseText.trimmingCharacters(in: .whitespacesAndNewlines)

        if let classificationResponseData = cleanedClassificationResponseText.data(using: .utf8),
           let classificationPayload = try? JSONDecoder().decode(
               ActionIntentClassificationPayload.self,
               from: classificationResponseData
           ) {
            return classificationPayload.intent
        }

        if let jsonObjectStartIndex = cleanedClassificationResponseText.firstIndex(of: "{"),
           let jsonObjectEndIndex = cleanedClassificationResponseText.lastIndex(of: "}") {
            let jsonObjectText = String(cleanedClassificationResponseText[jsonObjectStartIndex...jsonObjectEndIndex])
            if let jsonObjectData = jsonObjectText.data(using: .utf8),
               let classificationPayload = try? JSONDecoder().decode(
                   ActionIntentClassificationPayload.self,
                   from: jsonObjectData
               ) {
                return classificationPayload.intent
            }
        }

        let normalizedClassificationResponseText = cleanedClassificationResponseText.lowercased()
        if normalizedClassificationResponseText.contains("delegate") {
            return .delegate
        }
        if normalizedClassificationResponseText.contains("draft") {
            return .draft
        }
        return .reply
    }

    private func startMarkdownTranscriptGeneration(
        transcriptRequest: String,
        labeledImages: [(data: Data, label: String)]
    ) {
        currentMarkdownTranscriptTask?.cancel()
        currentMarkdownTranscriptTask = Task {
            defer { currentMarkdownTranscriptTask = nil }
            latestGeneratedMarkdownTranscriptText = nil
            companionResponseOverlayManager.showGeneratingMarkdownTranscriptStatus()

            do {
                let (markdownTranscriptText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.companionMarkdownTranscriptSystemPrompt,
                    userPrompt: transcriptRequest,
                    onTextChunk: { [weak self] _ in
                        guard let self else { return }
                        self.companionResponseOverlayManager.showGeneratingMarkdownTranscriptStatus()
                    }
                )

                guard !Task.isCancelled else { return }

                let savedMarkdownFileURL = try saveMarkdownTranscriptToDownloads(
                    markdownTranscriptText,
                    transcriptRequest: transcriptRequest
                )

                latestGeneratedMarkdownTranscriptText = markdownTranscriptText
                companionResponseOverlayManager.showReadyToCopyMarkdownTranscriptStatus()
                print("📝 Markdown transcript saved to \(savedMarkdownFileURL.path)")
            } catch is CancellationError {
                latestGeneratedMarkdownTranscriptText = nil
                companionResponseOverlayManager.hideMarkdownTranscriptOverlay()
            } catch {
                latestGeneratedMarkdownTranscriptText = nil
                companionResponseOverlayManager.showMarkdownTranscriptErrorStatus()
                print("⚠️ Markdown transcript generation error: \(error)")
            }
        }
    }

    private func saveMarkdownTranscriptToDownloads(
        _ markdownTranscriptText: String,
        transcriptRequest: String
    ) throws -> URL {
        let fileManager = FileManager.default
        let downloadsDirectoryURL = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let clickyTranscriptDirectoryURL = downloadsDirectoryURL.appendingPathComponent("Flowee Transcripts", isDirectory: true)

        try fileManager.createDirectory(
            at: clickyTranscriptDirectoryURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let suggestedPrefix = transcriptRequest.lowercased().contains("whiteboard")
            ? "whiteboard-transcript"
            : "flowee-transcript"

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        let timestampText = dateFormatter.string(from: Date())
        let fileURL = clickyTranscriptDirectoryURL.appendingPathComponent("\(suggestedPrefix)-\(timestampText).md")

        try markdownTranscriptText.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        stopAllSpeechPlayback()

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                print("🖼️ Companion captured \(screenCaptures.count) screen(s) for Claude")

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                let actionIntent = await classifyActionIntent(
                    transcript: transcript,
                    labeledImages: labeledImages
                )
                currentActionIntent = actionIntent

                if actionIntent == .delegate {
                    beginDelegationSelection(
                        transcript: transcript,
                        screenCaptures: screenCaptures
                    )
                    voiceState = .idle
                    return
                }

                if Self.shouldGenerateMarkdownTranscript(for: transcript) {
                    startMarkdownTranscriptGeneration(
                        transcriptRequest: transcript,
                        labeledImages: labeledImages
                    )
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

                guard !Task.isCancelled else { return }

                // Parse the [POINT:...] tag from Claude's response
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText
                print("🧠 Companion response ready: \(spokenText.count) spoken chars")

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await elevenLabsTTSClient.speakText(spokenText)
                        // speakText returns after player.play() — audio is now playing
                        voiceState = .responding
                    } catch {
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ ElevenLabs TTS error: \(error)")
                        speakErrorFallback(
                            "Something failed while I was trying to speak. Please check the Xcode console and try again."
                        )
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                let fallbackMessage: String
                let lowercaseErrorDescription = error.localizedDescription.lowercased()
                if lowercaseErrorDescription.contains("credit") {
                    fallbackMessage = "I'm all out of credits. Please top up the connected service and try again."
                } else {
                    fallbackMessage = "Something failed while I was generating a response. Please check the Xcode console and try again."
                }
                speakErrorFallback(fallbackMessage)
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    private func beginDelegationSelection(
        transcript: String,
        screenCaptures: [CompanionScreenCapture]
    ) {
        delegationAgentRuntimeRegistry.refreshInstalledRuntimes()
        let allowedWorkspaces = workspaceInventoryStore.enabledWorkspaces
        guard !allowedWorkspaces.isEmpty else {
            currentActionIntent = .reply
            pendingDelegationScreenCaptures = []
            pendingDelegationRequest = nil
            isAwaitingDelegationWorkspaceSelection = false
            selectedDelegationWorkspace = nil
            selectedDelegationRuntimeID = nil
            // Delegate mode is fully silent — no voice narration. The user will
            // see nothing happen and can check the Flowee menu for the empty
            // workspace inventory.
            print("🧭 Delegation aborted: no allowed workspaces configured")
            return
        }

        let installedAgentRuntimes = delegationAgentRuntimeRegistry.installedRuntimes
        guard !installedAgentRuntimes.isEmpty else {
            currentActionIntent = .reply
            pendingDelegationScreenCaptures = []
            pendingDelegationRequest = nil
            isAwaitingDelegationWorkspaceSelection = false
            selectedDelegationWorkspace = nil
            selectedDelegationRuntimeID = nil
            // Delegate mode is fully silent — no voice narration on the
            // missing-runtime error path either.
            print("🧭 Delegation aborted: no supported coding-agent CLIs detected on this machine")
            return
        }

        pendingDelegationScreenCaptures = screenCaptures
        pendingDelegationRequest = ClickyDelegationRequest(
            id: UUID(),
            transcript: transcript,
            screenSummary: screenCaptures.map(\.label).joined(separator: " | "),
            createdAt: Date()
        )
        isAwaitingDelegationWorkspaceSelection = true
        selectedDelegationWorkspace = nil
        delegationRepoPickerOverlayManager.show(
            workspaces: allowedWorkspaces,
            runtimes: installedAgentRuntimes,
            preselectedWorkspaceID: nil,
            preselectedRuntimeID: nil,
            title: "Delegate to workspace",
            detail: "Choose a workspace and agent runtime",
            onSelectionConfirmed: { [weak self] selection in
                self?.handleDelegationSelection(selection)
            },
            onCancelled: { [weak self] in
                self?.cancelPendingDelegationFlow()
            }
        )
        print("🧭 Delegation intent resolved — awaiting workspace selection")
    }

    func cancelPendingDelegationFlow() {
        delegationRepoPickerOverlayManager.hide()
        pendingDelegationScreenCaptures = []
        pendingDelegationRequest = nil
        isAwaitingDelegationWorkspaceSelection = false
        selectedDelegationWorkspace = nil
        selectedDelegationRuntimeID = nil
        currentActionIntent = .reply
    }

    func confirmDelegationSelection(
        workspace: WorkspaceInventoryStore.WorkspaceRecord,
        runtimeID: DelegationAgentRuntimeID
    ) {
        selectedDelegationWorkspace = workspace
        selectedDelegationRuntimeID = runtimeID
        isAwaitingDelegationWorkspaceSelection = false
        print("🧭 Delegation workspace selected: \(workspace.name) using \(runtimeID.displayName)")
    }

    private func handleDelegationSelection(_ selection: DelegationRepoPickerOverlayManager.DelegationSelection) {
        guard let matchedWorkspace = workspaceInventoryStore.workspaces.first(where: { $0.id == selection.workspace.id }),
              let matchedRuntime = delegationAgentRuntimeRegistry.installedRuntime(for: selection.runtime.id),
              let pendingDelegationRequest else {
            cancelPendingDelegationFlow()
            return
        }

        confirmDelegationSelection(
            workspace: matchedWorkspace,
            runtimeID: matchedRuntime.runtimeID
        )
        launchDelegatedAgentForPendingDelegation(
            request: pendingDelegationRequest,
            workspace: matchedWorkspace,
            runtime: matchedRuntime
        )
    }

    private func launchDelegatedAgentForPendingDelegation(
        request: ClickyDelegationRequest,
        workspace: WorkspaceInventoryStore.WorkspaceRecord,
        runtime: InstalledDelegationAgentRuntime
    ) {
        // Clicky serializes delegations per workspace: at most one
        // agent can run in any given workspace at a time. The agent
        // runs directly in the user's workspace (not a git worktree)
        // so their dev server / editor can hot-reload the agent's
        // edits as they land. If a previous delegation is still
        // running in this workspace, the new one joins that
        // workspace's FIFO queue and the sidebar immediately shows
        // a "queued" panel so the user knows it was accepted.

        let workspaceAlreadyHasRunningDelegation =
            activelyRunningDelegationSidebarSessionByWorkspaceID[workspace.id] != nil
        let queueLengthAheadOfThisOne =
            (delegationQueuesByWorkspaceID[workspace.id]?.count ?? 0)
                + (workspaceAlreadyHasRunningDelegation ? 1 : 0)

        let initialQueuePositionText: String
        if queueLengthAheadOfThisOne == 0 {
            initialQueuePositionText = "picking up now"
        } else if queueLengthAheadOfThisOne == 1 {
            initialQueuePositionText = "next up · 1 delegation ahead"
        } else {
            initialQueuePositionText = "waiting · \(queueLengthAheadOfThisOne) delegations ahead"
        }

        let sidebarSessionID = delegationLogSidebarManager.createQueuedSession(
            workspaceName: workspace.name,
            workspacePath: workspace.path,
            workspaceID: workspace.id,
            runtimeID: runtime.runtimeID,
            runtimeDisplayName: runtime.displayName,
            userTranscriptPreview: request.transcript,
            initialQueuePositionText: initialQueuePositionText
        )

        let enqueuedDelegation = EnqueuedDelegation(
            sidebarSessionID: sidebarSessionID,
            request: request,
            workspace: workspace,
            runtime: runtime
        )

        if workspaceAlreadyHasRunningDelegation {
            // Join the back of the queue — this one will be picked
            // up when the previous delegation for this workspace
            // exits.
            delegationQueuesByWorkspaceID[workspace.id, default: []].append(enqueuedDelegation)
            print("🧭 Delegation for \(workspace.name) enqueued at position \(queueLengthAheadOfThisOne) (behind a running agent)")
            refreshQueuePositionTextForRemainingEntries(inWorkspaceID: workspace.id)
        } else {
            // Nothing running — pick up immediately.
            activelyRunningDelegationSidebarSessionByWorkspaceID[workspace.id] = sidebarSessionID
            print("🧭 Delegation for \(workspace.name) picked up immediately (empty queue)")
            Task { await actuallyStartDelegatedAgent(enqueuedDelegation) }
        }

        cancelPendingDelegationFlow()
    }

    /// Does the real work of generating a branch-name hint, calling
    /// the launcher, and promoting the queued sidebar session to
    /// running. Called both for the immediate-start path and for
    /// queue-advance pickups after a previous delegation exits.
    private func actuallyStartDelegatedAgent(
        _ enqueuedDelegation: EnqueuedDelegation
    ) async {
        let launchPrompt = buildDelegatedAgentPrompt(
            request: enqueuedDelegation.request,
            workspace: enqueuedDelegation.workspace
        )

        do {
            // Ask the lightweight classifier to turn the user's
            // spoken request into a developer-friendly branch name
            // (e.g. `feature/dark-mode-settings`) before we cut the
            // actual git branch. This is best-effort — on failure we
            // pass nil and the launcher falls back to its legacy
            // timestamp-based branch name.
            let semanticBranchNameHint = await generateSemanticBranchNameHint(
                fromTranscript: enqueuedDelegation.request.transcript
            )
            if let semanticBranchNameHint {
                print("🌿 Semantic branch-name hint: \(semanticBranchNameHint)")
            }

            let launchResult = try await delegationAgentLauncher.launch(
                configuration: DelegationAgentLaunchConfiguration(
                    workspacePath: enqueuedDelegation.workspace.path,
                    prompt: launchPrompt,
                    runtime: enqueuedDelegation.runtime,
                    modelIdentifier: nil,
                    suggestedBranchNameHint: semanticBranchNameHint
                )
            )
            try? workspaceInventoryStore.markLastUsedDelegationRuntime(
                workspaceID: enqueuedDelegation.workspace.id,
                runtimeID: enqueuedDelegation.runtime.runtimeID
            )
            print("🧭 Delegation started in \(enqueuedDelegation.workspace.name) with \(launchResult.runtimeDisplayName), PID \(launchResult.processIdentifier)")
            print("🧭 Delegation log: \(launchResult.logFileURL.path)")

            let capturedWorkspaceID = enqueuedDelegation.workspace.id
            delegationLogSidebarManager.promoteQueuedSessionToRunning(
                sessionID: enqueuedDelegation.sidebarSessionID,
                logFileURL: launchResult.logFileURL,
                processIdentifier: launchResult.processIdentifier,
                baseBranchName: launchResult.baseBranchName,
                workingBranchName: launchResult.workingBranchName,
                comparePullRequestURL: launchResult.comparePullRequestURL,
                onProcessCompleteCallback: { [weak self] in
                    self?.advanceDelegationQueue(forWorkspaceID: capturedWorkspaceID)
                }
            )
            // Delegate mode is fully silent — no voice narration. The
            // delegation log sidebar is the only feedback surface
            // while the coding agent works.
        } catch {
            print("⚠️ Delegation launch failed in \(enqueuedDelegation.workspace.name): \(error)")
            // Surface the failure in the sidebar (the session was
            // already created in queued state — transition it to
            // failed state with the error message) so the user
            // isn't left staring at a queued panel that never
            // starts.
            delegationLogSidebarManager.markQueuedSessionAsFailed(
                sessionID: enqueuedDelegation.sidebarSessionID,
                errorMessage: error.localizedDescription
            )
            // This slot in the queue is now free — advance so the
            // next delegation in this workspace (if any) can take
            // its turn.
            advanceDelegationQueue(forWorkspaceID: enqueuedDelegation.workspace.id)
        }
    }

    /// Called when the currently-running delegation in a given
    /// workspace finishes (process exit). Pops the next queued
    /// delegation from that workspace's FIFO and promotes it to
    /// running; updates the visible queue-position text for every
    /// delegation that's still waiting behind it.
    private func advanceDelegationQueue(forWorkspaceID workspaceID: UUID) {
        // Free the "currently running" slot for this workspace so the
        // hasRunningDelegation check reads accurately.
        activelyRunningDelegationSidebarSessionByWorkspaceID.removeValue(forKey: workspaceID)

        var queueForWorkspace = delegationQueuesByWorkspaceID[workspaceID] ?? []
        guard !queueForWorkspace.isEmpty else {
            delegationQueuesByWorkspaceID[workspaceID] = nil
            return
        }

        let nextEnqueuedDelegation = queueForWorkspace.removeFirst()
        delegationQueuesByWorkspaceID[workspaceID] =
            queueForWorkspace.isEmpty ? nil : queueForWorkspace

        activelyRunningDelegationSidebarSessionByWorkspaceID[workspaceID] =
            nextEnqueuedDelegation.sidebarSessionID

        refreshQueuePositionTextForRemainingEntries(inWorkspaceID: workspaceID)

        print("🧭 Delegation queue for \(nextEnqueuedDelegation.workspace.name) advanced: picking up next delegation")
        Task { await actuallyStartDelegatedAgent(nextEnqueuedDelegation) }
    }

    /// Rewrites the user-visible queue-position text on every
    /// delegation that is still sitting in the queue for a given
    /// workspace, so the numbers stay accurate as the queue drains.
    private func refreshQueuePositionTextForRemainingEntries(inWorkspaceID workspaceID: UUID) {
        let queueForWorkspace = delegationQueuesByWorkspaceID[workspaceID] ?? []
        for (queueIndex, enqueuedDelegation) in queueForWorkspace.enumerated() {
            // queueIndex is 0-indexed within the waiting list; the
            // head of the waiting list is 1 step behind the currently
            // running delegation (position 1 in the user-visible
            // string).
            let positionAfterCurrentlyRunning = queueIndex + 1
            let updatedPositionText: String
            if positionAfterCurrentlyRunning == 1 {
                updatedPositionText = "next up · 1 delegation ahead"
            } else {
                updatedPositionText = "waiting · \(positionAfterCurrentlyRunning) delegations ahead"
            }
            delegationLogSidebarManager.updateQueuePositionText(
                sessionID: enqueuedDelegation.sidebarSessionID,
                newQueuePositionText: updatedPositionText
            )
        }
    }

    private func buildDelegatedAgentPrompt(
        request: ClickyDelegationRequest,
        workspace: WorkspaceInventoryStore.WorkspaceRecord
    ) -> String {
        let workspaceDescription = workspace.workspaceDescription.isEmpty
            ? "No additional workspace description was provided."
            : workspace.workspaceDescription

        return """
        You are working in the selected workspace: \(workspace.path)

        Workspace context:
        - Name: \(workspace.name)
        - Description: \(workspaceDescription)

        User request:
        \(request.transcript)

        Screen context:
        \(request.screenSummary)

        Task:
        - Inspect the repository and determine the smallest coherent change that addresses the request.
        - Treat the visible screen context as the source of truth for what the user is reacting to.
        - Make the change if it is well-scoped and safe to implement.
        - Summarize what changed, what you verified, and any remaining uncertainty.
        """
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while elevenLabsTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            while fallbackSpeechSynthesizer.isSpeaking {
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

    private func stopAllSpeechPlayback() {
        elevenLabsTTSClient.stopPlayback()
        if fallbackSpeechSynthesizer.isSpeaking {
            let currentFallbackSpeechIdentifierDescription = currentFallbackSpeechIdentifier?.uuidString ?? "unknown"
            print("🔊 Fallback speech: stopping [\(currentFallbackSpeechIdentifierDescription)]")
            fallbackSpeechSynthesizer.stopSpeaking()
        }
    }

    /// Speaks a local macOS fallback message when network TTS or response generation fails.
    private func speakErrorFallback(_ utterance: String) {
        stopAllSpeechPlayback()
        let fallbackSpeechIdentifier = UUID()
        currentFallbackSpeechIdentifier = fallbackSpeechIdentifier
        print("🔊 Fallback speech: starting [\(fallbackSpeechIdentifier.uuidString)] \(utterance)")
        fallbackSpeechSynthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        let currentFallbackSpeechIdentifierDescription = currentFallbackSpeechIdentifier?.uuidString ?? "unknown"
        print("🔊 Fallback speech: finished [\(currentFallbackSpeechIdentifierDescription)] success \(finishedSpeaking)")
        currentFallbackSpeechIdentifier = nil
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
        guard let videoURL = Self.onboardingVideoURL else {
            // Keep onboarding usable in builds that do not configure a video URL.
            startOnboardingPromptStream()
            return
        }

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
        // Clicky flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ClickyAnalytics.trackOnboardingVideoCompleted()
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
    you're flowee, a small purple cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

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
