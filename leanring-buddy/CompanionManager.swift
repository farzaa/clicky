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
import CoreFoundation
import Foundation
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasAutomationPermission = false
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

    /// When true, `BlueCursorView` snaps the buddy to `[POINT:...]` without the bezier flight
    /// after a turn that executed Computer Use actions (consumed when the overlay handles the point).
    @Published var shouldUseInstantBuddyNavigationToNextPoint = false

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

    let aiServiceSettings = AIServiceSettings()

    private lazy var openRouterAPI = OpenRouterAPI()
    private lazy var elevenLabsTTSClient = ElevenLabsTTSClient()
    private lazy var computerUseActionExecutor = ComputerUseActionExecutor()

    /// Retained instance so `stopSpeaking()` can run on quit. Throwaway `NSSpeechSynthesizer()` instances
    /// still enqueue utterances with the system speech service, which can keep talking after the app exits.
    private let systemSpeechSynthesizerForErrors = NSSpeechSynthesizer()

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []
    @Published private(set) var hasConversationHistory: Bool = false

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?
    private var pendingDestructiveActionPlan: [ResolvedComputerUseAction]?

    @Published private(set) var computerUseRuntimeStatusMessage: String = "Ready to control."

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?

    /// True while the global push-to-talk shortcut is held and we intend to record, including the
    /// async gap before `BuddyDictationManager` flips to actively recording. Keeps the overlay
    /// waveform in sync with user intent (and allows interrupting `.responding` when combined with
    /// the voice-state sink below).
    @Published private(set) var isPushToTalkHotkeyHeld = false
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    /// Throttles System Events AppleScript probes during timer-driven `refreshAllPermissions` so polling
    /// does not spam the same probe as the user-initiated Grant path (which logs diagnostics).
    private var lastAutomationPermissionProbeDateDuringPolling: Date?
    private let automationPermissionProbeMinimumIntervalDuringPolling: TimeInterval = 8
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?
    private var isOrchestratedLoopActive = false

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    @Published var availableOpenRouterModels: [OpenRouterModel] = []
    @Published var isLoadingOpenRouterModels = false
    @Published var openRouterModelsErrorMessage: String?

    var showOnlyWebEnabledModels: Bool {
        aiServiceSettings.showOnlyWebEnabledModels
    }

    var isComputerUseEnabled: Bool {
        aiServiceSettings.isComputerUseEnabled
    }

    var isMultiTurnEnabled: Bool {
        aiServiceSettings.isMultiTurnEnabled
    }

    var deferVoiceUntilAgenticLoopCompletes: Bool {
        aiServiceSettings.deferVoiceUntilAgenticLoopCompletes
    }

    var areComputerUsePermissionsGranted: Bool {
        hasAccessibilityPermission && hasAutomationPermission
    }

    var canPerformComputerUseActions: Bool {
        isComputerUseEnabled && areComputerUsePermissionsGranted
    }

    var computerUseBlockedReason: String? {
        if !isComputerUseEnabled {
            return "Computer Use is disabled. Enable it in Settings to allow click and type actions."
        }
        if !hasAccessibilityPermission {
            return "Accessibility permission is required for Computer Use."
        }
        if !hasAutomationPermission {
            return Self.computerUseAutomationDeniedStatusMessage
        }
        return nil
    }

    /// Short status line for the panel when Automation blocks execution.
    private static let computerUseAutomationDeniedStatusMessage =
        "Grant Automation (System Events) in Settings → Privacy & Security → Automation, or tap Grant next to Automation in Clicky’s Settings."

    /// Spoken guidance when execution is blocked because Automation is off.
    private static let computerUseAutomationDeniedSpokenGuidance =
        "i can't run clicks or typing until automation is on for system events. open clicky's settings tab and tap grant next to automation, or open system settings, privacy and security, automation, and allow clicky to control system events."

    private static let computerUseEnabledRecommendedOpenRouterModelID = "openai/gpt-5.4-mini"
    private static let computerUseEnabledRecommendedOrchestratorOpenRouterModelID = "openai/gpt-5.4"
    private static let computerUseDisabledRecommendedOpenRouterModelID = "anthropic/claude-sonnet-4.6"

    func computerUseAuthorizationStatus() -> (isAllowed: Bool, blockedReason: String?) {
        (canPerformComputerUseActions, computerUseBlockedReason)
    }

    var visibleOpenRouterModels: [OpenRouterModel] {
        if showOnlyWebEnabledModels {
            return availableOpenRouterModels.filter { $0.isWebBrowsingCapable }
        }
        return availableOpenRouterModels
    }

    var selectedModel: String {
        aiServiceSettings.selectedOpenRouterModelID
    }

    var orchestratorOpenRouterModelID: String {
        aiServiceSettings.orchestratorOpenRouterModelID
    }

    func setSelectedModel(_ model: String) {
        aiServiceSettings.saveSelectedOpenRouterModelID(model)
    }

    func setOrchestratorOpenRouterModelID(_ orchestratorOpenRouterModelID: String) {
        aiServiceSettings.saveOrchestratorOpenRouterModelID(orchestratorOpenRouterModelID)
    }

    func setShowOnlyWebEnabledModels(_ showOnlyWebEnabledModels: Bool) {
        aiServiceSettings.saveShowOnlyWebEnabledModels(showOnlyWebEnabledModels)
    }

    func setComputerUseEnabled(_ isComputerUseEnabled: Bool) {
        aiServiceSettings.saveComputerUseEnabled(isComputerUseEnabled)
        if isComputerUseEnabled {
            aiServiceSettings.saveSelectedOpenRouterModelID(Self.computerUseEnabledRecommendedOpenRouterModelID)
            aiServiceSettings.saveOrchestratorOpenRouterModelID(Self.computerUseEnabledRecommendedOrchestratorOpenRouterModelID)
        } else {
            aiServiceSettings.saveSelectedOpenRouterModelID(Self.computerUseDisabledRecommendedOpenRouterModelID)
            aiServiceSettings.saveOrchestratorOpenRouterModelID(Self.computerUseDisabledRecommendedOpenRouterModelID)
        }
        if isComputerUseEnabled {
            hasAutomationPermission = WindowPositionManager.hasAutomationPermissionForSystemEvents()
            lastAutomationPermissionProbeDateDuringPolling = Date()
            if !hasAutomationPermission {
                computerUseRuntimeStatusMessage = Self.computerUseAutomationDeniedStatusMessage
            } else {
                computerUseRuntimeStatusMessage = "Ready to control."
            }
        } else {
            hasAutomationPermission = false
            lastAutomationPermissionProbeDateDuringPolling = nil
            computerUseRuntimeStatusMessage = "Ready to control."
        }
    }

    func setMultiTurnEnabled(_ isMultiTurnEnabled: Bool) {
        aiServiceSettings.saveMultiTurnEnabled(isMultiTurnEnabled)
    }

    func setDeferVoiceUntilAgenticLoopCompletes(_ deferVoiceUntilAgenticLoopCompletes: Bool) {
        aiServiceSettings.saveDeferVoiceUntilAgenticLoopCompletes(deferVoiceUntilAgenticLoopCompletes)
    }

    @discardableResult
    func requestAutomationPermissionForComputerUse() -> PermissionRequestPresentationDestination {
        let presentationDestination = WindowPositionManager.requestAutomationPermissionForSystemEvents()
        hasAutomationPermission = WindowPositionManager.hasAutomationPermissionForSystemEvents()
        lastAutomationPermissionProbeDateDuringPolling = Date()
        return presentationDestination
    }

    /// Centralized gate for all computer-control actions (click/type/AppleScript).
    /// Future computer-use executors should call this before dispatching actions.
    func canExecuteComputerUseAction() -> Bool {
        canPerformComputerUseActions
    }

    /// Orders out full-screen cursor overlays momentarily so synthetic clicks reach the UI below.
    private func runComputerUseActionsWithOverlaySuppressedIfNeeded(
        actions: [ResolvedComputerUseAction]
    ) -> [ComputerUseActionExecutionResult] {
        let overlayWasVisible = overlayWindowManager.isShowingOverlay()
        if overlayWasVisible {
            overlayWindowManager.orderOutOverlayForSyntheticInput()
            usleep(50_000)
        }
        let executionResults = computerUseActionExecutor.execute(actions: actions)
        if overlayWasVisible {
            overlayWindowManager.restoreOverlayAfterSyntheticInput()
        }
        return executionResults
    }

    func saveOpenRouterAPIKey(_ openRouterAPIKey: String) -> String? {
        do {
            try aiServiceSettings.saveOpenRouterAPIKey(openRouterAPIKey)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func saveElevenLabsAPIKey(_ elevenLabsAPIKey: String) -> String? {
        do {
            try aiServiceSettings.saveElevenLabsAPIKey(elevenLabsAPIKey)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func saveElevenLabsVoiceID(_ elevenLabsVoiceID: String) {
        aiServiceSettings.saveElevenLabsVoiceID(elevenLabsVoiceID)
    }

    func refreshOpenRouterModels() {
        guard aiServiceSettings.hasOpenRouterAPIKey else {
            availableOpenRouterModels = []
            openRouterModelsErrorMessage = "Add an OpenRouter API key first."
            return
        }

        openRouterModelsErrorMessage = nil
        isLoadingOpenRouterModels = true

        Task {
            defer { isLoadingOpenRouterModels = false }
            do {
                let models = try await openRouterAPI.fetchModels(apiKey: aiServiceSettings.openRouterAPIKey)
                await MainActor.run {
                    availableOpenRouterModels = models
                    openRouterModelsErrorMessage = models.isEmpty ? "No models returned from OpenRouter." : nil
                    let defaultModelPool: [OpenRouterModel]
                    if aiServiceSettings.showOnlyWebEnabledModels {
                        defaultModelPool = models.filter { $0.isWebBrowsingCapable }
                    } else {
                        defaultModelPool = models
                    }
                    if let firstModel = defaultModelPool.first,
                       !models.contains(where: { $0.id == aiServiceSettings.selectedOpenRouterModelID }) {
                        aiServiceSettings.saveSelectedOpenRouterModelID(firstModel.id)
                    }
                    if let firstModel = defaultModelPool.first,
                       !models.contains(where: { $0.id == aiServiceSettings.orchestratorOpenRouterModelID }) {
                        aiServiceSettings.saveOrchestratorOpenRouterModelID(firstModel.id)
                    }
                }
            } catch {
                await MainActor.run {
                    availableOpenRouterModels = []
                    openRouterModelsErrorMessage = error.localizedDescription
                }
            }
        }
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

    /// Stores onboarding email locally only.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")
    }

    func start() {
        aiServiceSettings.reloadSecureValues()
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        // Eagerly touch the OpenRouter API so TLS warmup completes early.
        // well before the onboarding demo fires at ~40s into the video.
        _ = openRouterAPI
        if aiServiceSettings.hasOpenRouterAPIKey {
            refreshOpenRouterModels()
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
        shouldUseInstantBuddyNavigationToNextPoint = false
    }

    /// Resets the in-memory conversation context used for follow-up turns.
    /// This keeps permissions/settings untouched while starting a fresh chat thread.
    func clearConversationContext() {
        elevenLabsTTSClient.stopPlayback()
        abortActiveOrchestratedLoopIfNeeded(reason: "context_cleared")
        conversationHistory.removeAll()
        hasConversationHistory = false
        pendingDestructiveActionPlan = nil
        print("🧠 Conversation history cleared by user.")
    }

    func stop() {
        elevenLabsTTSClient.stopPlayback()
        systemSpeechSynthesizerForErrors.stopSpeaking()
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil

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

    func refreshAllPermissions(forceImmediateAutomationPermissionRecheck: Bool = false) {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadAutomation = hasAutomationPermission
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
        if !isComputerUseEnabled {
            hasAutomationPermission = false
            lastAutomationPermissionProbeDateDuringPolling = nil
        } else {
            let shouldRunAutomationProbe: Bool
            if forceImmediateAutomationPermissionRecheck {
                shouldRunAutomationProbe = true
            } else if lastAutomationPermissionProbeDateDuringPolling == nil {
                shouldRunAutomationProbe = true
            } else {
                shouldRunAutomationProbe = Date().timeIntervalSince(lastAutomationPermissionProbeDateDuringPolling!) >= automationPermissionProbeMinimumIntervalDuringPolling
            }
            if shouldRunAutomationProbe {
                hasAutomationPermission = WindowPositionManager.hasAutomationPermissionForSystemEvents()
                lastAutomationPermissionProbeDateDuringPolling = Date()
            }
        }

        if isComputerUseEnabled {
            if hasAccessibilityPermission && hasAutomationPermission {
                computerUseRuntimeStatusMessage = "Ready to control."
            } else if !hasAccessibilityPermission {
                computerUseRuntimeStatusMessage = "Accessibility permission is required for Computer Use."
            } else if !hasAutomationPermission {
                computerUseRuntimeStatusMessage = Self.computerUseAutomationDeniedStatusMessage
            }
        }

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadAutomation != hasAutomationPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), automation: \(hasAutomationPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
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
        voiceStateCancellable = Publishers.CombineLatest4(
            buddyDictationManager.$isFinalizingTranscript,
            buddyDictationManager.$isPreparingToRecord,
            buddyDictationManager.$isRecordingFromKeyboardShortcut,
            buddyDictationManager.$isRecordingFromMicrophoneButton
        )
        .combineLatest($isPushToTalkHotkeyHeld)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] dictationTuple, hotkeyHeld in
            guard let self else { return }

            let (
                isFinalizing,
                isPreparing,
                isRecordingFromKeyboardShortcut,
                isRecordingFromMicrophoneButton
            ) = dictationTuple
            let isActivelyRecording = isRecordingFromKeyboardShortcut || isRecordingFromMicrophoneButton

            // Keep `.responding` while the assistant is talking, unless the user is interrupting
            // with push-to-talk (hotkey held) or dictation has already moved on.
            let shouldAllowDictationToDriveVoiceState =
                self.voiceState != .responding
                || isFinalizing
                || isActivelyRecording
                || hotkeyHeld
            guard shouldAllowDictationToDriveVoiceState else { return }

            if isFinalizing {
                self.voiceState = .processing
            } else if isActivelyRecording || hotkeyHeld {
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
            abortActiveOrchestratedLoopIfNeeded(reason: "hotkey_pressed")
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
    

            ClickyAnalytics.trackPushToTalkStarted()

            isPushToTalkHotkeyHeld = true

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
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            abortActiveOrchestratedLoopIfNeeded(reason: "hotkey_released")
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
            isPushToTalkHotkeyHeld = false
        case .none:
            break
        }
    }

    private func abortActiveOrchestratedLoopIfNeeded(reason: String) {
        guard isOrchestratedLoopActive else { return }
        print("🧠 Multi-turn loop stop reason: \(reason)")
        currentResponseTask?.cancel()
        currentResponseTask = nil
        pendingDestructiveActionPlan = nil
        voiceState = .idle
        scheduleTransientHideIfNeeded()
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you get one screenshot: the display where their cursor is. your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - speak in the same language as the user's latest message unless they ask you to switch. do not force english.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - never narrate internal metadata or control syntax in the spoken text. do not say things like actions json, point tag, coordinates, x/y values, screen numbers, cursor metadata, or execution metadata out loud.
    - never read aloud bracket tags, json blocks, scroll deltas, loop control fields, or the phrases loop control or actions json — the app strips machine syntax from audio, but your spoken lines must stay conversational.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - when the user asks for current events, recent updates, live pricing, version changes, or anything time-sensitive, use the web_search tool first and ground your answer in those results.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - you only see that one display — you cannot see other monitors. if the user needs help on another screen, tell them to move the pointer there and ask again.

    loop control contract:
    - always include a machine-readable block anywhere in your response using this exact format:
      [LOOP_CONTROL]{"decision":"continue|complete","reason":"short reason","nextUserVisibleGoal":"short goal","mode":"act|observe","maxObserveSeconds":number}[/LOOP_CONTROL]
    - choose "continue" only when there is a clear next autonomous step you can execute now.
    - choose "complete" when the task is done, blocked, uncertain, waiting for user input, or your next step would repeat the same click or scroll without new visible progress.
    - if you are waiting for a page, search results, spinner, or async ui update to settle, use "decision":"continue" with "mode":"observe" (never "complete" for that waiting state).
    - use "mode":"act" when the next step should execute actions immediately.
    - use "mode":"observe" when the app should poll screenshots for visual change first.
    - keep reason and nextUserVisibleGoal short and plain text.
    - never omit the [LOOP_CONTROL] block on any autonomous continuation turn — without it the app stops the loop.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). do not use :screenN — only this one display is captured.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    """

    private static let companionVoiceResponseSystemPromptWhenComputerUseEnabled = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you get one screenshot: the display where their cursor is. your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - speak in the same language as the user's latest message unless they ask you to switch. do not force english.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - never narrate internal metadata or control syntax in the spoken text. do not say things like actions json, point tag, coordinates, x/y values, screen numbers, cursor metadata, or execution metadata out loud.
    - never read aloud bracket tags, json blocks, scroll deltas, loop control fields, or the phrases loop control or actions json — the app strips machine syntax from audio, but your spoken lines must stay conversational.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - when the user asks for current events, recent updates, live pricing, version changes, or anything time-sensitive, use the web_search tool first and ground your answer in those results.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - you only see that one display — you cannot see other monitors. if the user needs help on another screen, tell them to move the pointer there and ask again.

    computer use mode:
    - computer use is enabled. the app will execute your json actions locally. you are not allowed to only tell the user to click — you must emit the machine actions yourself.
    - critical: if the user asks you to click, double-click, right-click, type, press keys, scroll, or drag on screen, you MUST include a non-empty [ACTIONS_JSON] block before your [POINT:...] tag with at least one action that performs that step. pointing alone is never enough for those requests. do not answer with only "you should click" or "click that tab" without the actions json.
    - scrolling web pages: the blue [POINT:...] cursor is visual only — it does not move the real mouse. put scroll "x" and "y" inside [ACTIONS_JSON] on the main scrollable page column (not the image bottom edge or dock); those coordinates move the real pointer for wheel events. the app does not replace scroll x,y with [POINT:...] — point is overlay-only for scroll. without x,y on scroll, wheel events may apply to the wrong window.
    - only use [ACTIONS_JSON]{"actions":[]}[/ACTIONS_JSON] when the user is not asking for any on-screen control (pure explanation, general knowledge, or no specific ui step).
    - prefer concrete operational guidance in speech, but the real click/type must appear in actions json.
    - if a request maps to a visible ui workflow, choose a specific next interaction target, put left_click (or type_text, etc.) in actions json, then point to the same target in [POINT:...] for the blue cursor.
    - browser tab bars are easy to get wrong: read the exact tab title visible in the screenshot, place x,y at the horizontal center of that title (not an adjacent tab), and use the same integers for left_click in [ACTIONS_JSON] and for [POINT:...].
    - never claim you already clicked, typed, or completed a step unless that action is confirmed by visible state in the screenshots.
    - when the task cannot be confirmed from screenshots, still emit the best-effort actions json for the next likely step if the user asked for control; say you're trying that step in speech.
    - include an actions block before your [POINT:...] tag with exact json in this format:
      [ACTIONS_JSON]{"actions":[{"type":"left_click","x":123,"y":456},{"type":"type_text","text":"hello"},{"type":"key_combo","key":"k","modifiers":["command"]},{"type":"scroll","x":640,"y":400,"deltaX":0,"deltaY":-24},{"type":"drag","startX":300,"startY":500,"endX":900,"endY":500},{"type":"right_click","x":444,"y":222},{"type":"double_click","x":444,"y":222},{"type":"key_press","key":"return"}]}[/ACTIONS_JSON]
    - scroll deltas deltaX/deltaY are in wheel lines per step. negative deltaY reads further down the page in the screenshot; keep each scroll action roughly between -80 and -8 lines (or small positive values if you need the opposite) — the app clamps huge values and matches the user’s natural scrolling setting.
    - coordinates in the actions block use the same screenshot pixel coordinate system as [POINT:...]. optional "screen" in json is ignored — only this display is captured.

    loop control contract:
    - always include a machine-readable block anywhere in your response using this exact format:
      [LOOP_CONTROL]{"decision":"continue|complete","reason":"short reason","nextUserVisibleGoal":"short goal","mode":"act|observe","maxObserveSeconds":number}[/LOOP_CONTROL]
    - choose "continue" only when there is a clear next autonomous step you can execute now.
    - choose "complete" when the task is done, blocked, uncertain, waiting for user input, would otherwise loop, or your next step would repeat the same interaction without new visible progress.
    - if you are waiting for a page, search results, spinner, or async ui update to settle, use "decision":"continue" with "mode":"observe" (never "complete" for that waiting state).
    - use "mode":"act" when the next step should execute actions immediately.
    - use "mode":"observe" when the app should poll screenshots for visual change first.
    - keep reason and nextUserVisibleGoal short and plain text.
    - never omit the [LOOP_CONTROL] block on any autonomous continuation turn — without it the app stops the loop.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific ui element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). do not use :screenN — only this one display is captured.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    """

    private var activeCompanionVoiceSystemPrompt: String {
        if isComputerUseEnabled {
            return Self.companionVoiceResponseSystemPromptWhenComputerUseEnabled
        }
        return Self.companionVoiceResponseSystemPrompt
    }

    // MARK: - AI Response Pipeline

    private func openRouterModelIDForMultiTurnLoopVisionCall(userPromptForCurrentTurn: String) -> String {
        if Self.isMultiTurnContinuationUserPrompt(userPromptForCurrentTurn) {
            return aiServiceSettings.orchestratorOpenRouterModelID
        }
        return aiServiceSettings.selectedOpenRouterModelID
    }

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()

        currentResponseTask = Task {
            voiceState = .processing
            isOrchestratedLoopActive = true
            defer { isOrchestratedLoopActive = false }

            do {
                guard aiServiceSettings.hasOpenRouterAPIKey else {
                    throw NSError(domain: "CompanionManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing OpenRouter API key. Add it in Settings."])
                }

                var initialUserPromptForLoop = transcript
                if isComputerUseEnabled, let pendingDestructiveActionPlan {
                    if isAffirmativeConfirmation(transcript) {
                        let pendingExecutionResults = runComputerUseActionsWithOverlaySuppressedIfNeeded(
                            actions: pendingDestructiveActionPlan
                        )
                        let didAllPendingActionsSucceed = pendingExecutionResults.allSatisfy(\.isSuccess)
                        let pendingFailureSummary = pendingExecutionResults
                            .compactMap(\.failureReason)
                            .joined(separator: " ")
                        self.pendingDestructiveActionPlan = nil
                        computerUseRuntimeStatusMessage = didAllPendingActionsSucceed
                            ? "Executed confirmed action."
                            : "Action failed: \(pendingFailureSummary)"
                        let confirmationSpokenText = didAllPendingActionsSucceed
                            ? "done. i executed that now."
                            : "i tried that but hit an issue. \(pendingFailureSummary)"
                        try await elevenLabsTTSClient.speakText(
                            confirmationSpokenText,
                            apiKey: aiServiceSettings.elevenLabsAPIKey,
                            voiceID: aiServiceSettings.elevenLabsVoiceID
                        )
                        voiceState = .responding
                        if !isMultiTurnEnabled {
                            return
                        }
                        // Resume the orchestrated loop automatically after explicit confirmation
                        // so the user doesn't need another push-to-talk turn.
                        initialUserPromptForLoop = Self.multiTurnContinuationUserPrompt
                    }
                    if isNegativeConfirmation(transcript) {
                        self.pendingDestructiveActionPlan = nil
                        computerUseRuntimeStatusMessage = "Destructive action cancelled."
                        try await elevenLabsTTSClient.speakText(
                            "okay, cancelled. i won't run that.",
                            apiKey: aiServiceSettings.elevenLabsAPIKey,
                            voiceID: aiServiceSettings.elevenLabsVoiceID
                        )
                        voiceState = .responding
                        return
                    }
                    self.pendingDestructiveActionPlan = nil
                }

                let shouldRunMultiTurnLoop = isMultiTurnEnabled
                var userPromptForCurrentTurn = initialUserPromptForLoop
                var scrollObserveLoopStreak = 0
                var autonomousLoopIterationCount = 0
                var previousSuccessfulAutonomousActionFingerprint: String?
                var consecutiveDuplicateAutonomousActionPlanCount = 0

                while true {
                    guard !Task.isCancelled else { return }

                    autonomousLoopIterationCount += 1
                    if autonomousLoopIterationCount > Self.maxAutonomousLoopIterationsPerVoiceRequest {
                        print("🧠 Multi-turn loop stop reason: max_autonomous_iterations")
                        break
                    }

                    let screenCaptures = try await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG()
                    guard !Task.isCancelled else { return }

                    let labeledImages = screenCaptures.map { capture in
                        let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                        return (data: capture.imageData, label: capture.label + dimensionInfo)
                    }

                    let historyForAPI = conversationHistory.map { entry in
                        (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                    }

                    let shouldSkipOpenRouterWebSearchAugmentation =
                        isComputerUseEnabled && Self.userTranscriptImpliesComputerControlRequest(userPromptForCurrentTurn)

                    let openRouterModelIDForThisVisionCall = openRouterModelIDForMultiTurnLoopVisionCall(
                        userPromptForCurrentTurn: userPromptForCurrentTurn
                    )
                    print("🌐 OpenRouter model for this loop step: \(openRouterModelIDForThisVisionCall)")

                    var (fullResponseText, _) = try await openRouterAPI.analyzeImageStreaming(
                        apiKey: aiServiceSettings.openRouterAPIKey,
                        selectedModel: openRouterModelIDForThisVisionCall,
                        knownModels: availableOpenRouterModels,
                        images: labeledImages,
                        systemPrompt: activeCompanionVoiceSystemPrompt,
                        conversationHistory: historyForAPI,
                        userPrompt: userPromptForCurrentTurn,
                        forceDisableWebSearchAugmentation: shouldSkipOpenRouterWebSearchAugmentation,
                        onTextChunk: { _ in }
                    )
                    guard !Task.isCancelled else { return }

                    var parsedAssistantResponse = parseAssistantResponse(from: fullResponseText)
                    if isComputerUseEnabled,
                       canExecuteComputerUseAction(),
                       Self.userTranscriptImpliesComputerControlRequest(userPromptForCurrentTurn) {
                        let missingOrEmptyActions =
                            !parsedAssistantResponse.didMatchActionsJSONDelimiters
                            || parsedAssistantResponse.actionInstructions.isEmpty
                        if missingOrEmptyActions {
                            (fullResponseText, _) = try await openRouterAPI.analyzeImageStreaming(
                                apiKey: aiServiceSettings.openRouterAPIKey,
                                selectedModel: openRouterModelIDForThisVisionCall,
                                knownModels: availableOpenRouterModels,
                                images: labeledImages,
                                systemPrompt: activeCompanionVoiceSystemPrompt,
                                conversationHistory: historyForAPI,
                                userPrompt: userPromptForCurrentTurn + Self.computerUseRetryUserPromptSuffix,
                                forceDisableWebSearchAugmentation: shouldSkipOpenRouterWebSearchAugmentation,
                                onTextChunk: { _ in }
                            )
                            guard !Task.isCancelled else { return }
                            parsedAssistantResponse = parseAssistantResponse(from: fullResponseText)
                        }
                    }

                    if shouldRunMultiTurnLoop,
                       !parsedAssistantResponse.loopControlResult.didMatchLoopControlDelimiters {
                        (fullResponseText, _) = try await openRouterAPI.analyzeImageStreaming(
                            apiKey: aiServiceSettings.openRouterAPIKey,
                            selectedModel: openRouterModelIDForThisVisionCall,
                            knownModels: availableOpenRouterModels,
                            images: labeledImages,
                            systemPrompt: activeCompanionVoiceSystemPrompt,
                            conversationHistory: historyForAPI,
                            userPrompt: userPromptForCurrentTurn + Self.loopControlRetryUserPromptSuffix,
                            forceDisableWebSearchAugmentation: shouldSkipOpenRouterWebSearchAugmentation,
                            onTextChunk: { _ in }
                        )
                        guard !Task.isCancelled else { return }
                        parsedAssistantResponse = parseAssistantResponse(from: fullResponseText)
                    }

                    var spokenText = parsedAssistantResponse.spokenText
                    let parseResult = parsedAssistantResponse.pointingResult
                    let loopControlResult = parsedAssistantResponse.loopControlResult
                    print(
                        "🧠 Multi-turn loop decision: \(loopControlResult.decision.rawValue), " +
                        "reason=\(loopControlResult.reason ?? "none"), " +
                        "goal=\(loopControlResult.nextUserVisibleGoal ?? "none"), " +
                        "mode=\(loopControlResult.mode.rawValue), " +
                        "maxObserveSeconds=\(loopControlResult.maxObserveSeconds.map { String(format: "%.1f", $0) } ?? "none"), " +
                        "validJSON=\(loopControlResult.wasValidJSON)"
                    )
                    let mergedComputerUseActionInstructions = computerUseActionInstructionsByMergingPointTagIfUnambiguous(
                        actionInstructions: parsedAssistantResponse.actionInstructions,
                        pointingParseResult: parseResult,
                        screenCaptures: screenCaptures
                    )
                    let resolvedComputerUseActions = resolveComputerUseActions(
                        from: mergedComputerUseActionInstructions,
                        using: screenCaptures
                    )
                    let lastStepIncludedScrollWithFocus = resolvedComputerUseActions.contains { resolvedAction in
                        if case .scroll(_, _, let focusGlobalPoint) = resolvedAction {
                            return focusGlobalPoint != nil
                        }
                        return false
                    }

                    var didExecuteComputerUseActionsSuccessfully = false
                    var isLoopBlockedByComputerUsePermissions = false

                    if isComputerUseEnabled {
                        if resolvedComputerUseActions.isEmpty,
                           Self.userTranscriptImpliesComputerControlRequest(userPromptForCurrentTurn) {
                            print("🖱️ Computer use: no executable actions — check for missing or invalid [ACTIONS_JSON] in the model response.")
                        } else {
                            print("🖱️ Computer use: \(resolvedComputerUseActions.count) resolved action(s).")
                        }
                    }

                    if isComputerUseEnabled, !resolvedComputerUseActions.isEmpty {
                        if canExecuteComputerUseAction() {
                            if actionPlanContainsDestructiveAction(resolvedComputerUseActions) {
                                pendingDestructiveActionPlan = resolvedComputerUseActions
                                computerUseRuntimeStatusMessage = "Waiting for destructive action confirmation."
                                spokenText += " this step can be destructive. say confirm to run it, or say cancel."
                            } else {
                                let executionResults = runComputerUseActionsWithOverlaySuppressedIfNeeded(
                                    actions: resolvedComputerUseActions
                                )
                                let didAllActionsSucceed = executionResults.allSatisfy(\.isSuccess)
                                didExecuteComputerUseActionsSuccessfully = didAllActionsSucceed
                                if didAllActionsSucceed {
                                    computerUseRuntimeStatusMessage = "Executed action."
                                } else {
                                    let failureSummary = executionResults.compactMap(\.failureReason).joined(separator: " ")
                                    computerUseRuntimeStatusMessage = "Action failed: \(failureSummary)"
                                    spokenText += " i tried to run that but hit an issue. \(failureSummary)"
                                }
                            }
                        } else {
                            isLoopBlockedByComputerUsePermissions = true
                            if !hasAccessibilityPermission {
                                let accessibilityBlockedReason = "Accessibility permission is required for Computer Use."
                                computerUseRuntimeStatusMessage = accessibilityBlockedReason
                                spokenText += " \(accessibilityBlockedReason)"
                            } else if !hasAutomationPermission {
                                computerUseRuntimeStatusMessage = Self.computerUseAutomationDeniedStatusMessage
                                spokenText += " \(Self.computerUseAutomationDeniedSpokenGuidance)"
                            } else {
                                let blockedReason = computerUseBlockedReason ?? "Computer Use is not allowed right now."
                                computerUseRuntimeStatusMessage = blockedReason
                                spokenText += " \(blockedReason)"
                            }
                            pendingDestructiveActionPlan = nil
                        }
                    } else if isComputerUseEnabled {
                        computerUseRuntimeStatusMessage = "Ready to control."
                    }

                    if didExecuteComputerUseActionsSuccessfully, !resolvedComputerUseActions.isEmpty {
                        let autonomousActionFingerprint = Self.quantizedResolvedActionPlanFingerprint(
                            resolvedComputerUseActions
                        )
                        if let previousFingerprint = previousSuccessfulAutonomousActionFingerprint,
                           previousFingerprint == autonomousActionFingerprint {
                            consecutiveDuplicateAutonomousActionPlanCount += 1
                        } else {
                            consecutiveDuplicateAutonomousActionPlanCount = 0
                        }
                        previousSuccessfulAutonomousActionFingerprint = autonomousActionFingerprint
                    }

                    let hasPointCoordinate = parseResult.coordinate != nil
                    if hasPointCoordinate {
                        voiceState = .idle
                    }

                    let targetScreenCapture: CompanionScreenCapture? = {
                        if let screenNumber = parseResult.screenNumber,
                           screenNumber >= 1 && screenNumber <= screenCaptures.count {
                            return screenCaptures[screenNumber - 1]
                        }
                        return screenCaptures.first(where: { $0.isCursorScreen })
                    }()

                    if let pointCoordinate = parseResult.coordinate,
                       let targetScreenCapture {
                        let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                        let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                        let displayFrame = targetScreenCapture.displayFrame
                        let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                        let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                        let globalLocation = targetScreenCapture.globalAppKitPointFromScreenshotPixelCoordinate(
                            screenshotPixelX: clampedX,
                            screenshotPixelY: clampedY
                        )

                        if didExecuteComputerUseActionsSuccessfully {
                            shouldUseInstantBuddyNavigationToNextPoint = true
                        }
                        detectedElementScreenLocation = globalLocation
                        detectedElementDisplayFrame = displayFrame
                        logComputerUsePixelToGlobalMapping(
                            context: "point_tag_overlay",
                            screenshotPixelX: clampedX,
                            screenshotPixelY: clampedY,
                            targetScreenCapture: targetScreenCapture,
                            globalPoint: globalLocation
                        )
                        print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                    } else {
                        print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                    }

                    conversationHistory.append((
                        userTranscript: userPromptForCurrentTurn,
                        assistantResponse: spokenText
                    ))
                    hasConversationHistory = !conversationHistory.isEmpty
                    if conversationHistory.count > 10 {
                        conversationHistory.removeFirst(conversationHistory.count - 10)
                    }
                    hasConversationHistory = !conversationHistory.isEmpty
                    print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                    let shouldPlayVoiceThisTurn = Self.shouldPlayVoiceThisMultiTurnIteration(
                        deferVoiceUntilAgenticLoopCompletes: aiServiceSettings.deferVoiceUntilAgenticLoopCompletes,
                        shouldRunMultiTurnLoop: shouldRunMultiTurnLoop,
                        pendingDestructiveActionPlan: pendingDestructiveActionPlan,
                        isLoopBlockedByComputerUsePermissions: isLoopBlockedByComputerUsePermissions,
                        loopControlResult: loopControlResult
                    )

                    if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if shouldPlayVoiceThisTurn {
                            do {
                                try await elevenLabsTTSClient.speakText(
                                    spokenText,
                                    apiKey: aiServiceSettings.elevenLabsAPIKey,
                                    voiceID: aiServiceSettings.elevenLabsVoiceID
                                )
                                voiceState = .responding
                            } catch {
                                print("⚠️ ElevenLabs TTS error: \(error)")
                                if !isUserCancellationOrAbortError(error) {
                                    speakErrorWithSystemSpeechSynthesizer(error: error, failureStage: .textToSpeech)
                                }
                            }
                        } else {
                            print("🔇 Voice deferred until agentic loop completes (settings).")
                            voiceState = .processing
                        }
                    }

                    if !shouldRunMultiTurnLoop || pendingDestructiveActionPlan != nil {
                        if !shouldRunMultiTurnLoop {
                            print("🧠 Multi-turn loop stop reason: multi_turn_disabled")
                        } else {
                            print("🧠 Multi-turn loop stop reason: pending_destructive_confirmation")
                        }
                        break
                    }

                    if isLoopBlockedByComputerUsePermissions {
                        print("🧠 Multi-turn loop stop reason: computer_use_permission_blocked")
                        break
                    }

                    let shouldContinueLoop = loopControlResult.decision == .continue
                    if !shouldContinueLoop {
                        let completionReason = loopControlResult.reason ?? "model_complete"
                        print("🧠 Multi-turn loop stop reason: \(completionReason)")
                        break
                    }

                    if loopControlResult.mode == .observe {
                        let requestedObserveTimeoutInSeconds = loopControlResult.maxObserveSeconds
                            ?? defaultObserveModeTimeoutInSeconds
                        print(
                            "🧠 Observe mode: polling for visual change up to " +
                            "\(String(format: "%.1f", requestedObserveTimeoutInSeconds))s."
                        )
                        let observeOutcome = await waitForVisualChangeInObserveMode(
                            maxObserveSeconds: requestedObserveTimeoutInSeconds
                        )
                        let didDetectVisualChange = observeOutcome.didDetectVisualChange
                        if didDetectVisualChange {
                            print("🧠 Observe mode: continuing after visual change.")
                            if observeOutcome.pollCountWhenFinished == 1 && lastStepIncludedScrollWithFocus {
                                scrollObserveLoopStreak += 1
                            } else {
                                scrollObserveLoopStreak = 0
                            }
                        } else {
                            print("🧠 Observe mode: no visual change before timeout; continuing to next model turn.")
                            if lastStepIncludedScrollWithFocus && observeOutcome.pollCountWhenFinished > 0 {
                                scrollObserveLoopStreak += 1
                            } else {
                                scrollObserveLoopStreak = 0
                            }
                        }
                    } else {
                        scrollObserveLoopStreak = 0
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    guard !Task.isCancelled else { return }

                    if consecutiveDuplicateAutonomousActionPlanCount >= 2 {
                        print("🧠 Multi-turn loop stop reason: repeated_action_plan")
                        break
                    }

                    voiceState = .processing
                    userPromptForCurrentTurn = Self.multiTurnContinuationUserPrompt
                    if scrollObserveLoopStreak >= 3 {
                        userPromptForCurrentTurn += Self.multiTurnScrollObserveRemediationUserPromptSuffix
                        scrollObserveLoopStreak = 0
                    }
                    print("🧠 Multi-turn loop continuing autonomously.")
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                if isUserCancellationOrAbortError(error) {
                    // Task or URLSession cancelled (e.g. user cleared context); do not speak.
                } else {
                    print("⚠️ Companion response error: \(error)")
                    speakErrorWithSystemSpeechSynthesizer(error: error, failureStage: .responsePipeline)
                }
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
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

    private enum CompanionSystemSpeechFailureStage {
        case textToSpeech
        case responsePipeline
    }

    /// Builds a short spoken line for failures in the chat or TTS pipeline.
    /// The “credits / hiccup” copy is reserved for HTTP statuses and error text
    /// that plausibly indicate quota or billing — not for local audio decode
    /// or playback failures (those get a plain retry message).
    private func systemSpeechUtterance(for error: Error, failureStage: CompanionSystemSpeechFailureStage) -> String {
        let rootError = error as NSError
        let combinedLowercasedTextForKeywordMatching: String = {
            var parts: [String] = [rootError.localizedDescription]
            if let underlyingError = rootError.userInfo[NSUnderlyingErrorKey] as? NSError {
                parts.append(underlyingError.localizedDescription)
            }
            return parts.joined(separator: " ").lowercased()
        }()

        func combinedTextIndicatesQuotaOrBillingIssue() -> Bool {
            combinedLowercasedTextForKeywordMatching.contains("quota")
                || combinedLowercasedTextForKeywordMatching.contains("credit")
                || combinedLowercasedTextForKeywordMatching.contains("insufficient")
                || combinedLowercasedTextForKeywordMatching.contains("balance")
                || combinedLowercasedTextForKeywordMatching.contains("billing")
        }

        let creditsOrHiccupUtterance =
            "Oops, I'm either out of credits or experiencing a small hiccup. Check your credits and try again."

        if rootError.domain == "CompanionManager" {
            return rootError.localizedDescription
        }

        switch failureStage {
        case .responsePipeline:
            if rootError.domain == NSURLErrorDomain {
                return "Sorry, the network dropped while I was working. Please check your connection and try again."
            }

            if rootError.domain == "OpenRouterAPI" {
                let statusCode = rootError.code
                if statusCode == 401 {
                    return "Your OpenRouter API key was rejected. Check it in Settings."
                }
                if statusCode == 402 || statusCode == 429 || combinedTextIndicatesQuotaOrBillingIssue() {
                    return creditsOrHiccupUtterance
                }
                return "Sorry, something went wrong while I was responding. Please try again."
            }

            return "Sorry, something went wrong while I was responding. Please try again."

        case .textToSpeech:
            if rootError.domain == NSURLErrorDomain {
                return "Sorry, I couldn't reach ElevenLabs to play audio. Check your connection and try again."
            }

            if rootError.domain == "ElevenLabsTTS" {
                let statusCode = rootError.code
                if statusCode == 401 {
                    return "Your ElevenLabs API key was rejected. Check it in Settings."
                }
                if statusCode == 402 || statusCode == 429 || combinedTextIndicatesQuotaOrBillingIssue() {
                    return creditsOrHiccupUtterance
                }
            }

            return "Sorry, I couldn't play the voice audio. Please try again."
        }
    }

    /// True when the failure was caused by cancelling the task or URLSession (e.g. user cleared
    /// context), not a real network or API error — callers should not play error speech.
    private func isUserCancellationOrAbortError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }
        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isUserCancellationOrAbortError(underlyingError)
        }
        return false
    }

    /// Speaks using macOS system TTS when ElevenLabs playback fails or the main
    /// pipeline errors. Uses NSSpeechSynthesizer so something is still audible.
    private func speakErrorWithSystemSpeechSynthesizer(
        error: Error,
        failureStage: CompanionSystemSpeechFailureStage
    ) {
        let utterance = systemSpeechUtterance(for: error, failureStage: failureStage)
        systemSpeechSynthesizerForErrors.stopSpeaking()
        systemSpeechSynthesizerForErrors.startSpeaking(utterance)
        voiceState = .responding
    }

    // MARK: - Computer Use Action Parsing

    private struct ParsedAssistantResponse {
        let spokenText: String
        let pointingResult: PointingParseResult
        let actionInstructions: [ComputerUseActionInstruction]
        let didMatchActionsJSONDelimiters: Bool
        let loopControlResult: LoopControlParseResult
    }

    private struct ComputerUseActionEnvelope: Decodable {
        let actions: [ComputerUseActionInstruction]
    }

    private enum LoopControlDecision: String, Decodable {
        case `continue`
        case complete
    }

    private enum LoopControlMode: String, Decodable {
        case act
        case observe
    }

    private struct LoopControlEnvelope: Decodable {
        let decision: LoopControlDecision
        let reason: String?
        let nextUserVisibleGoal: String?
        let mode: LoopControlMode?
        let maxObserveSeconds: Double?
    }

    private struct LoopControlParseResult {
        let decision: LoopControlDecision
        let reason: String?
        let nextUserVisibleGoal: String?
        let mode: LoopControlMode
        let maxObserveSeconds: TimeInterval?
        let didMatchLoopControlDelimiters: Bool
        let wasValidJSON: Bool
    }

    /// When deferral is enabled, skip ElevenLabs on intermediate `[LOOP_CONTROL]` `continue` steps so the user only hears audio after the agentic loop exits.
    private static func shouldPlayVoiceThisMultiTurnIteration(
        deferVoiceUntilAgenticLoopCompletes: Bool,
        shouldRunMultiTurnLoop: Bool,
        pendingDestructiveActionPlan: [ResolvedComputerUseAction]?,
        isLoopBlockedByComputerUsePermissions: Bool,
        loopControlResult: LoopControlParseResult
    ) -> Bool {
        guard deferVoiceUntilAgenticLoopCompletes, shouldRunMultiTurnLoop else { return true }
        if pendingDestructiveActionPlan != nil { return true }
        if isLoopBlockedByComputerUsePermissions { return true }
        return loopControlResult.decision != .continue
    }

    private func parseAssistantResponse(from fullResponseText: String) -> ParsedAssistantResponse {
        let loopControlParseResult = Self.parseLoopControlBlock(from: fullResponseText)
        let actionParseResult = Self.parseComputerUseActionsBlock(from: fullResponseText)
        let spokenTextSanitizedForVoice = Self.spokenTextSanitizedForVoice(from: fullResponseText)
        let pointingResult = Self.parsePointingCoordinates(
            from: fullResponseText,
            sanitizedSpokenText: spokenTextSanitizedForVoice
        )
        let pointingResultWithSharedSpokenText = PointingParseResult(
            spokenText: spokenTextSanitizedForVoice,
            coordinate: pointingResult.coordinate,
            elementLabel: pointingResult.elementLabel,
            screenNumber: pointingResult.screenNumber
        )
        return ParsedAssistantResponse(
            spokenText: spokenTextSanitizedForVoice,
            pointingResult: pointingResultWithSharedSpokenText,
            actionInstructions: actionParseResult.actionInstructions,
            didMatchActionsJSONDelimiters: actionParseResult.didMatchActionsJSONDelimiters,
            loopControlResult: loopControlParseResult
        )
    }

    // MARK: - Machine syntax stripping (TTS + conversation history)

    private static let loopControlMachineBlockRegexPattern =
        #"\[LOOP_CONTROL\]\s*\{[\s\S]*?\}\s*\[/LOOP_CONTROL\]"#
    private static let actionsJsonMachineBlockRegexPattern =
        #"\[ACTIONS_JSON\]\s*\{[\s\S]*?\}\s*\[/ACTIONS_JSON\]"#
    /// Matches any `[POINT:...]` tag the overlay understands, for removal from spoken output.
    private static let pointMachineTagRegexPattern =
        #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]"#

    private static func removeAllRegexMatches(from text: String, pattern: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return text
        }
        var result = text
        while true {
            let searchRange = NSRange(result.startIndex..., in: result)
            guard let match = regex.firstMatch(in: result, options: [], range: searchRange),
                  let swiftRange = Range(match.range, in: result) else {
                break
            }
            result.removeSubrange(swiftRange)
        }
        return result
    }

    /// Removes every machine-readable block so ElevenLabs and history never receive JSON or tags.
    private static func spokenTextSanitizedForVoice(from fullResponseText: String) -> String {
        var result = fullResponseText
        result = removeAllRegexMatches(from: result, pattern: loopControlMachineBlockRegexPattern)
        result = removeAllRegexMatches(from: result, pattern: actionsJsonMachineBlockRegexPattern)
        result = removeAllRegexMatches(from: result, pattern: pointMachineTagRegexPattern)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result
    }

    private static func parseLoopControlBlock(from responseText: String) -> LoopControlParseResult {
        let pattern = #"\[LOOP_CONTROL\]\s*(\{[\s\S]*?\})\s*\[/LOOP_CONTROL\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return LoopControlParseResult(
                decision: .complete,
                reason: "missing_loop_control_block",
                nextUserVisibleGoal: nil,
                mode: .act,
                maxObserveSeconds: nil,
                didMatchLoopControlDelimiters: false,
                wasValidJSON: false
            )
        }

        let allMatches = regex.matches(in: responseText, range: NSRange(responseText.startIndex..., in: responseText))
        guard !allMatches.isEmpty else {
            return LoopControlParseResult(
                decision: .complete,
                reason: "missing_loop_control_block",
                nextUserVisibleGoal: nil,
                mode: .act,
                maxObserveSeconds: nil,
                didMatchLoopControlDelimiters: false,
                wasValidJSON: false
            )
        }

        var lastSuccessfullyDecodedResult: LoopControlParseResult?
        for match in allMatches {
            guard let jsonRange = Range(match.range(at: 1), in: responseText) else { continue }
            let jsonString = String(responseText[jsonRange])
            guard let jsonData = jsonString.data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(LoopControlEnvelope.self, from: jsonData) else {
                continue
            }
            lastSuccessfullyDecodedResult = LoopControlParseResult(
                decision: envelope.decision,
                reason: envelope.reason,
                nextUserVisibleGoal: envelope.nextUserVisibleGoal,
                mode: envelope.mode ?? .act,
                maxObserveSeconds: envelope.maxObserveSeconds,
                didMatchLoopControlDelimiters: true,
                wasValidJSON: true
            )
        }

        if let lastSuccessfullyDecodedResult {
            return lastSuccessfullyDecodedResult
        }

        return LoopControlParseResult(
            decision: .complete,
            reason: "invalid_loop_control_json",
            nextUserVisibleGoal: nil,
            mode: .act,
            maxObserveSeconds: nil,
            didMatchLoopControlDelimiters: true,
            wasValidJSON: false
        )
    }

    private static func parseComputerUseActionsBlock(
        from responseText: String
    ) -> (
        actionInstructions: [ComputerUseActionInstruction],
        didMatchActionsJSONDelimiters: Bool
    ) {
        let pattern = #"\[ACTIONS_JSON\]\s*(\{[\s\S]*?\})\s*\[/ACTIONS_JSON\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return ([], false)
        }

        let allMatches = regex.matches(in: responseText, range: NSRange(responseText.startIndex..., in: responseText))
        guard !allMatches.isEmpty else {
            return ([], false)
        }

        var mergedActionInstructions: [ComputerUseActionInstruction] = []
        for match in allMatches {
            guard let jsonRange = Range(match.range(at: 1), in: responseText) else { continue }
            let jsonString = String(responseText[jsonRange])
            guard let jsonData = jsonString.data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(ComputerUseActionEnvelope.self, from: jsonData) else {
                continue
            }
            mergedActionInstructions.append(contentsOf: envelope.actions)
        }

        return (mergedActionInstructions, true)
    }

    /// True when the user is asking for on-screen control (click, type, etc.), not pure Q&A.
    private static let maxAutonomousLoopIterationsPerVoiceRequest = 50
    private static let autonomousLoopActionCoordinateQuantizationStepInPoints: CGFloat = 5

    /// Caps model-provided scroll deltas so one step cannot post hundreds of wheel ticks.
    private static let computerUseScrollDeltaMagnitudeCapInLines: Double = 120

    private static func isMacOSNaturalScrollingEnabled() -> Bool {
        guard let value = CFPreferencesCopyAppValue(
            "com.apple.swipescrolldirection" as CFString,
            kCFPreferencesAnyApplication
        ) else {
            return true
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return true
    }

    /// Clamps per-step scroll deltas and inverts when macOS natural scrolling is on so synthetic wheel
    /// events match how the user expects content to move for a given sign.
    private static func normalizedScrollDeltaForComputerUse(deltaX: Double, deltaY: Double) -> (Double, Double) {
        let cap = computerUseScrollDeltaMagnitudeCapInLines
        func clampMagnitude(_ value: Double) -> Double {
            guard value != 0 else { return 0 }
            let sign = value > 0 ? 1.0 : -1.0
            return sign * min(abs(value), cap)
        }
        var nextX = clampMagnitude(deltaX)
        var nextY = clampMagnitude(deltaY)
        if isMacOSNaturalScrollingEnabled() {
            nextX = -nextX
            nextY = -nextY
        }
        return (nextX, nextY)
    }

    /// Nudges scroll wheel focus away from the Dock (bottom) and menu bar (top) in AppKit global space.
    private static func scrollFocusGlobalPointClampedToSafeDisplayInset(
        rawGlobalPoint: CGPoint,
        displayFrame: CGRect
    ) -> CGPoint {
        let horizontalInsetInPoints: CGFloat = 12
        let topInsetInPoints: CGFloat = 28
        let bottomInsetInPoints: CGFloat = 100

        let minX = displayFrame.minX + horizontalInsetInPoints
        let maxX = displayFrame.maxX - horizontalInsetInPoints
        let minY = displayFrame.minY + bottomInsetInPoints
        let maxY = displayFrame.maxY - topInsetInPoints

        guard maxX >= minX, maxY >= minY else {
            return rawGlobalPoint
        }

        return CGPoint(
            x: min(max(rawGlobalPoint.x, minX), maxX),
            y: min(max(rawGlobalPoint.y, minY), maxY)
        )
    }

    /// Stable fingerprint for consecutive-turn duplicate detection after successful computer-use execution.
    private static func quantizedResolvedActionPlanFingerprint(
        _ actions: [ResolvedComputerUseAction]
    ) -> String {
        func quantizedGridIndex(for coordinateValue: CGFloat) -> Int {
            Int(round(coordinateValue / autonomousLoopActionCoordinateQuantizationStepInPoints))
        }
        func quantizedPointFingerprint(_ point: CGPoint) -> String {
            "\(quantizedGridIndex(for: point.x)),\(quantizedGridIndex(for: point.y))"
        }
        return actions.map { resolvedAction in
            switch resolvedAction {
            case .leftClick(let globalPoint):
                return "L:\(quantizedPointFingerprint(globalPoint))"
            case .doubleClick(let globalPoint):
                return "D:\(quantizedPointFingerprint(globalPoint))"
            case .rightClick(let globalPoint):
                return "R:\(quantizedPointFingerprint(globalPoint))"
            case .typeText(let text):
                return "T:\(text.prefix(120))"
            case .keyPress(let key):
                return "K:\(key.lowercased())"
            case .keyCombo(let key, let modifiers):
                let sortedModifierSummary = modifiers.map { $0.lowercased() }.sorted().joined(separator: ",")
                return "C:\(key.lowercased())[\(sortedModifierSummary)]"
            case .scroll(let deltaX, let deltaY, let focusGlobalPoint):
                let quantizedDeltaX = Int(round(deltaX / 2))
                let quantizedDeltaY = Int(round(deltaY / 2))
                let focusSummary = focusGlobalPoint.map { "F:\(quantizedPointFingerprint($0))" } ?? "F:nil"
                return "S:\(quantizedDeltaX),\(quantizedDeltaY),\(focusSummary)"
            case .drag(let startGlobalPoint, let endGlobalPoint):
                return "G:\(quantizedPointFingerprint(startGlobalPoint))-\(quantizedPointFingerprint(endGlobalPoint))"
            }
        }.joined(separator: "|")
    }

    private static func userTranscriptImpliesComputerControlRequest(_ transcript: String) -> Bool {
        let normalized = transcript.lowercased()
        let controlKeywords = [
            "click", "double click", "double-click", "right click", "right-click",
            "type ", "type this", "press ", "hit ", "tap ",
            "scroll", "drag", "select ", "open tab", "close tab",
            "submit", "send ", "focus", "navigate to",
            "do it for me", "you click", "yourself", "computer use"
        ]
        return controlKeywords.contains(where: { normalized.contains($0) })
    }

    private static let computerUseRetryUserPromptSuffix = """

    [clicky system reminder: computer use is on. you MUST output a non-empty [ACTIONS_JSON] block before [POINT:...] for this request. use valid json like {"actions":[{"type":"left_click","x":123,"y":456}]} with integer x,y in screenshot pixel space from the image labels. do not only describe what the user should click.]
    """

    private static let loopControlRetryUserPromptSuffix = """

    [clicky system reminder: multi-turn loop is on. you MUST include a valid [LOOP_CONTROL]{...}[/LOOP_CONTROL] block in your reply with json keys decision, reason, nextUserVisibleGoal, mode, and maxObserveSeconds when relevant. example: [LOOP_CONTROL]{"decision":"continue","reason":"waiting for ui","nextUserVisibleGoal":"see results","mode":"observe","maxObserveSeconds":4}[/LOOP_CONTROL]
    """

    private static let multiTurnContinuationUserPrompt = """

    [clicky system continuation: continue autonomously from the latest screen state and prior context. if more steps are needed, do the next best step now. if the task appears complete or blocked and needs user input, say so clearly.]
    """

    /// Appended to continuation turns when scrolling likely failed to move the viewport (observe-mode heuristics).
    private static let multiTurnScrollObserveRemediationUserPromptSuffix = """

    [clicky system reminder: if you were trying to scroll a web page, the viewport may not have moved. put x and y on the main page body inside [ACTIONS_JSON] scroll (not the dock or image bottom edge), use a moderate deltaY (e.g. -16 to -48 lines per step), or left_click the article body first then scroll — [POINT:...] does not override scroll coordinates and does not move the system pointer for scrolling.]
    """

    private static func isMultiTurnContinuationUserPrompt(_ userPromptForCurrentTurn: String) -> Bool {
        let trimmed = userPromptForCurrentTurn.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseContinuation = multiTurnContinuationUserPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == baseContinuation || trimmed.hasPrefix(baseContinuation)
    }

    private let observeModePollingIntervalInSeconds: TimeInterval = 0.6
    private let defaultObserveModeTimeoutInSeconds: TimeInterval = 6
    private let maxObserveModeTimeoutInSeconds: TimeInterval = 20

    private func observeModeScreenshotSignatures(for screenCaptures: [CompanionScreenCapture]) -> [Int: UInt64] {
        Dictionary(uniqueKeysWithValues: screenCaptures.enumerated().map { screenCaptureIndex, screenCapture in
            (screenCaptureIndex, observeModeStableScreenshotSignature(for: screenCapture.imageData))
        })
    }

    /// Stable signature for observe-mode polling: JPEG bytes vary run-to-run; TIFF from decoded bitmap is stable for identical pixels.
    private func observeModeStableScreenshotSignature(for imageData: Data) -> UInt64 {
        if let image = NSImage(data: imageData),
           let stableBitmapData = image.tiffRepresentation {
            return rollingScreenshotByteSampleSignature(for: stableBitmapData)
        }
        return rollingScreenshotByteSampleSignature(for: imageData)
    }

    private func rollingScreenshotByteSampleSignature(for imageData: Data) -> UInt64 {
        let sampleLimit = min(imageData.count, 4096)
        guard sampleLimit > 0 else { return 0 }
        let samplingStride = max(sampleLimit / 64, 1)
        var rollingSignature: UInt64 = 1469598103934665603
        var sampledIndex = 0
        while sampledIndex < sampleLimit {
            let sampledByte = UInt64(imageData[sampledIndex])
            rollingSignature ^= sampledByte
            rollingSignature &*= 1099511628211
            sampledIndex += samplingStride
        }
        rollingSignature ^= UInt64(imageData.count)
        rollingSignature &*= 1099511628211
        return rollingSignature
    }

    private func screenshotSignature(for imageData: Data) -> UInt64 {
        rollingScreenshotByteSampleSignature(for: imageData)
    }

    private func didScreenSignaturesChange(
        baselineSignatures: [Int: UInt64],
        latestSignatures: [Int: UInt64]
    ) -> Bool {
        if baselineSignatures.count != latestSignatures.count {
            return true
        }
        return baselineSignatures.contains { screenCaptureIndex, baselineSignature in
            latestSignatures[screenCaptureIndex] != baselineSignature
        }
    }

    private struct ObserveModeVisualChangeOutcome {
        let didDetectVisualChange: Bool
        /// Poll index when a change was first detected, or the number of polls completed before giving up.
        let pollCountWhenFinished: Int
    }

    private func waitForVisualChangeInObserveMode(maxObserveSeconds: TimeInterval) async -> ObserveModeVisualChangeOutcome {
        let clampedObserveTimeoutInSeconds = min(
            max(maxObserveSeconds, observeModePollingIntervalInSeconds),
            maxObserveModeTimeoutInSeconds
        )
        var pollAttemptCount = 0
        do {
            let baselineScreenCaptures = try await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG()
            let baselineSignatures = observeModeScreenshotSignatures(for: baselineScreenCaptures)
            let observeDeadline = Date().addingTimeInterval(clampedObserveTimeoutInSeconds)
            while Date() < observeDeadline {
                guard !Task.isCancelled else {
                    return ObserveModeVisualChangeOutcome(didDetectVisualChange: false, pollCountWhenFinished: pollAttemptCount)
                }
                pollAttemptCount += 1
                try? await Task.sleep(nanoseconds: UInt64(observeModePollingIntervalInSeconds * 1_000_000_000))
                guard !Task.isCancelled else {
                    return ObserveModeVisualChangeOutcome(didDetectVisualChange: false, pollCountWhenFinished: pollAttemptCount)
                }
                let latestScreenCaptures = try await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG()
                let latestSignatures = observeModeScreenshotSignatures(for: latestScreenCaptures)
                if didScreenSignaturesChange(baselineSignatures: baselineSignatures, latestSignatures: latestSignatures) {
                    print("🧠 Observe mode: visual change detected after \(pollAttemptCount) poll(s).")
                    return ObserveModeVisualChangeOutcome(didDetectVisualChange: true, pollCountWhenFinished: pollAttemptCount)
                }
                print("🧠 Observe mode: no visual change yet (poll \(pollAttemptCount)).")
            }
        } catch {
            print("⚠️ Observe mode polling failed: \(error.localizedDescription)")
        }
        return ObserveModeVisualChangeOutcome(didDetectVisualChange: false, pollCountWhenFinished: pollAttemptCount)
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

    /// Parses the last `[POINT:x,y:label:screenN]` or `[POINT:none]` in the response (order-independent).
    /// Pass `sanitizedSpokenText` when the caller already computed it to avoid stripping twice.
    static func parsePointingCoordinates(
        from responseText: String,
        sanitizedSpokenText: String? = nil
    ) -> PointingParseResult {
        let sanitizedSpokenTextResolved = sanitizedSpokenText ?? spokenTextSanitizedForVoice(from: responseText)
        guard let regex = try? NSRegularExpression(pattern: pointMachineTagRegexPattern, options: []) else {
            return PointingParseResult(
                spokenText: sanitizedSpokenTextResolved,
                coordinate: nil,
                elementLabel: nil,
                screenNumber: nil
            )
        }

        let allMatches = regex.matches(in: responseText, options: [], range: NSRange(responseText.startIndex..., in: responseText))
        guard let match = allMatches.last else {
            return PointingParseResult(
                spokenText: sanitizedSpokenTextResolved,
                coordinate: nil,
                elementLabel: nil,
                screenNumber: nil
            )
        }

        let xCaptureRange = match.range(at: 1)
        if xCaptureRange.location == NSNotFound || xCaptureRange.length == 0 {
            return PointingParseResult(
                spokenText: sanitizedSpokenTextResolved,
                coordinate: nil,
                elementLabel: "none",
                screenNumber: nil
            )
        }

        guard let xRange = Range(xCaptureRange, in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(
                spokenText: sanitizedSpokenTextResolved,
                coordinate: nil,
                elementLabel: "none",
                screenNumber: nil
            )
        }

        var elementLabel: String?
        let labelCaptureRange = match.range(at: 3)
        if labelCaptureRange.location != NSNotFound,
           labelCaptureRange.length > 0,
           let labelRange = Range(labelCaptureRange, in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int?
        let screenCaptureRange = match.range(at: 4)
        if screenCaptureRange.location != NSNotFound,
           screenCaptureRange.length > 0,
           let screenRange = Range(screenCaptureRange, in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: sanitizedSpokenTextResolved,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    /// When the model emits both `[POINT:...]` and `[ACTIONS_JSON]` with a single spatial click action,
    /// use the point tag as the source of truth so the overlay and HID actions stay aligned.
    /// Scroll is excluded: `[ACTIONS_JSON]` scroll `x,y` must drive wheel focus (POINTER labels often sit on
    /// bottom-of-image pixels that map to the Dock when merged).
    private func computerUseActionInstructionsByMergingPointTagIfUnambiguous(
        actionInstructions: [ComputerUseActionInstruction],
        pointingParseResult: PointingParseResult,
        screenCaptures: [CompanionScreenCapture]
    ) -> [ComputerUseActionInstruction] {
        guard let pointCoordinate = pointingParseResult.coordinate else {
            return actionInstructions
        }
        guard actionInstructions.count == 1,
              let onlyInstruction = actionInstructions.first else {
            return actionInstructions
        }

        let normalizedType = onlyInstruction.type.lowercased()
        let singleSpatialMergeTypes: Set<String> = ["left_click", "double_click", "right_click"]
        guard singleSpatialMergeTypes.contains(normalizedType) else {
            return actionInstructions
        }

        let pointX = Double(pointCoordinate.x)
        let pointY = Double(pointCoordinate.y)
        let pointScreen = pointingParseResult.screenNumber

        let jsonX = onlyInstruction.x
        let jsonY = onlyInstruction.y
        let jsonScreen = onlyInstruction.screen

        let jsonDisagreesWithPoint: Bool = {
            if let jsonX, abs(jsonX - pointX) > 0.5 { return true }
            if let jsonY, abs(jsonY - pointY) > 0.5 { return true }
            if let jsonScreen, let pointScreen, jsonScreen != pointScreen { return true }
            return false
        }()

        if jsonDisagreesWithPoint {
            let captureForPoint = screenCaptureForComputerUse(screen: pointScreen, screenCaptures: screenCaptures)
            let captureForJson = screenCaptureForComputerUse(screen: jsonScreen, screenCaptures: screenCaptures)
            let mergedCapture = captureForJson ?? captureForPoint
            print(
                "🖱️ Computer use: [POINT:...] overrides [ACTIONS_JSON] for single spatial action — " +
                "POINT=(\(pointX),\(pointY)) screen=\(String(describing: pointScreen)) " +
                "vs JSON=(\(String(describing: jsonX)),\(String(describing: jsonY))) screen=\(String(describing: jsonScreen))"
            )
            if let captureP = captureForPoint {
                let pointGlobal = captureP.globalAppKitPointFromScreenshotPixelCoordinate(
                    screenshotPixelX: CGFloat(pointX),
                    screenshotPixelY: CGFloat(pointY)
                )
                if let jx = jsonX, let jy = jsonY, let capJ = mergedCapture {
                    let jsonGlobal = capJ.globalAppKitPointFromScreenshotPixelCoordinate(
                        screenshotPixelX: CGFloat(jx),
                        screenshotPixelY: CGFloat(jy)
                    )
                    print(
                        "🖱️ Computer use: resolved global POINT=\(pointGlobal) vs JSON=\(jsonGlobal) " +
                        "frameSource_point=\(captureP.displayFrameMappingSourceDescription) " +
                        "frameSource_json=\(capJ.displayFrameMappingSourceDescription)"
                    )
                }
            }
        }

        return [
            onlyInstruction.replacingSpatialFields(x: pointX, y: pointY, screen: pointScreen)
        ]
    }

    private func screenCaptureForComputerUse(
        screen: Int?,
        screenCaptures: [CompanionScreenCapture]
    ) -> CompanionScreenCapture? {
        if let screen, screen >= 1, screen <= screenCaptures.count {
            return screenCaptures[screen - 1]
        }
        return screenCaptures.first(where: { $0.isCursorScreen })
    }

    /// Logs how screenshot pixel coordinates map to global AppKit points for Computer Use / pointing.
    private func logComputerUsePixelToGlobalMapping(
        context: String,
        screenshotPixelX: CGFloat,
        screenshotPixelY: CGFloat,
        targetScreenCapture: CompanionScreenCapture,
        globalPoint: CGPoint
    ) {
        let screenshotWidthInPixels = CGFloat(targetScreenCapture.screenshotWidthInPixels)
        let screenshotHeightInPixels = CGFloat(targetScreenCapture.screenshotHeightInPixels)
        let pointsPerPixelX = targetScreenCapture.displayFrame.width / max(screenshotWidthInPixels, 1)
        let pointsPerPixelY = targetScreenCapture.displayFrame.height / max(screenshotHeightInPixels, 1)
        print(
            "🖱️ Computer use mapping [\(context)]: pixel=(\(String(format: "%.1f", screenshotPixelX)),\(String(format: "%.1f", screenshotPixelY))) " +
            "→ global=\(globalPoint) displayFrame=\(targetScreenCapture.displayFrame) " +
            "mappingFrameSource=\(targetScreenCapture.displayFrameMappingSourceDescription) " +
            "ptsPerPx=(\(String(format: "%.4f", pointsPerPixelX)),\(String(format: "%.4f", pointsPerPixelY))) " +
            "screenshotPx=\(targetScreenCapture.screenshotWidthInPixels)x\(targetScreenCapture.screenshotHeightInPixels)"
        )
    }

    private func resolveComputerUseActions(
        from actionInstructions: [ComputerUseActionInstruction],
        using screenCaptures: [CompanionScreenCapture]
    ) -> [ResolvedComputerUseAction] {
        actionInstructions.compactMap { actionInstruction in
            switch actionInstruction.type.lowercased() {
            case "left_click":
                guard let globalPoint = resolveGlobalPoint(
                    x: actionInstruction.x,
                    y: actionInstruction.y,
                    screen: actionInstruction.screen,
                    screenCaptures: screenCaptures
                ) else { return nil }
                return .leftClick(globalPoint: globalPoint)
            case "double_click":
                guard let globalPoint = resolveGlobalPoint(
                    x: actionInstruction.x,
                    y: actionInstruction.y,
                    screen: actionInstruction.screen,
                    screenCaptures: screenCaptures
                ) else { return nil }
                return .doubleClick(globalPoint: globalPoint)
            case "right_click":
                guard let globalPoint = resolveGlobalPoint(
                    x: actionInstruction.x,
                    y: actionInstruction.y,
                    screen: actionInstruction.screen,
                    screenCaptures: screenCaptures
                ) else { return nil }
                return .rightClick(globalPoint: globalPoint)
            case "type_text":
                guard let text = actionInstruction.text else { return nil }
                return .typeText(text)
            case "key_press":
                guard let key = actionInstruction.key else { return nil }
                return .keyPress(key)
            case "key_combo":
                guard let key = actionInstruction.key else { return nil }
                return .keyCombo(key: key, modifiers: actionInstruction.modifiers ?? [])
            case "scroll":
                let rawDeltaX = actionInstruction.deltaX ?? 0
                let rawDeltaY = actionInstruction.deltaY ?? 0
                let (deltaX, deltaY) = Self.normalizedScrollDeltaForComputerUse(deltaX: rawDeltaX, deltaY: rawDeltaY)
                let focusGlobalPoint: CGPoint? = {
                    guard let focusX = actionInstruction.x, let focusY = actionInstruction.y else {
                        return nil
                    }
                    guard let resolvedFocus = resolveGlobalPoint(
                        x: focusX,
                        y: focusY,
                        screen: actionInstruction.screen,
                        screenCaptures: screenCaptures
                    ),
                          let targetScreenCapture = screenCaptureForComputerUse(
                            screen: actionInstruction.screen,
                            screenCaptures: screenCaptures
                          ) else {
                        return nil
                    }
                    let clampedFocus = Self.scrollFocusGlobalPointClampedToSafeDisplayInset(
                        rawGlobalPoint: resolvedFocus,
                        displayFrame: targetScreenCapture.displayFrame
                    )
                    let driftInPoints = hypot(clampedFocus.x - resolvedFocus.x, clampedFocus.y - resolvedFocus.y)
                    if driftInPoints > 0.5 {
                        print(
                            "🖱️ Computer use scroll: focus clamped for Dock/menu clearance " +
                            "raw=\(resolvedFocus) clamped=\(clampedFocus) displayFrame=\(targetScreenCapture.displayFrame)"
                        )
                    }
                    return clampedFocus
                }()
                if abs(rawDeltaX - deltaX) > 0.01 || abs(rawDeltaY - deltaY) > 0.01 {
                    print(
                        "🖱️ Computer use scroll: normalized model delta " +
                        "(\(rawDeltaX),\(rawDeltaY)) → (\(deltaX),\(deltaY)) " +
                        "(cap=\(Int(Self.computerUseScrollDeltaMagnitudeCapInLines)) lines, " +
                        "naturalScroll=\(Self.isMacOSNaturalScrollingEnabled()))"
                    )
                }
                return .scroll(deltaX: deltaX, deltaY: deltaY, focusGlobalPoint: focusGlobalPoint)
            case "drag":
                guard let startGlobalPoint = resolveGlobalPoint(
                    x: actionInstruction.startX,
                    y: actionInstruction.startY,
                    screen: actionInstruction.screen,
                    screenCaptures: screenCaptures
                ), let endGlobalPoint = resolveGlobalPoint(
                    x: actionInstruction.endX,
                    y: actionInstruction.endY,
                    screen: actionInstruction.screen,
                    screenCaptures: screenCaptures
                ) else { return nil }
                return .drag(fromGlobalPoint: startGlobalPoint, toGlobalPoint: endGlobalPoint)
            default:
                return nil
            }
        }
    }

    private func resolveGlobalPoint(
        x: Double?,
        y: Double?,
        screen: Int?,
        screenCaptures: [CompanionScreenCapture]
    ) -> CGPoint? {
        guard let x, let y else { return nil }
        guard let targetScreenCapture = screenCaptureForComputerUse(screen: screen, screenCaptures: screenCaptures) else {
            return nil
        }
        let globalPoint = targetScreenCapture.globalAppKitPointFromScreenshotPixelCoordinate(
            screenshotPixelX: CGFloat(x),
            screenshotPixelY: CGFloat(y)
        )
        let screenIndexDescription: String
        if let screen, screen >= 1 {
            screenIndexDescription = "\(screen)"
        } else {
            screenIndexDescription = "cursor_screen_fallback"
        }
        logComputerUsePixelToGlobalMapping(
            context: "actions_json_screen_\(screenIndexDescription)",
            screenshotPixelX: CGFloat(x),
            screenshotPixelY: CGFloat(y),
            targetScreenCapture: targetScreenCapture,
            globalPoint: globalPoint
        )
        return globalPoint
    }

    private func actionPlanContainsDestructiveAction(_ actionPlan: [ResolvedComputerUseAction]) -> Bool {
        actionPlan.contains { resolvedComputerUseAction in
            switch resolvedComputerUseAction {
            case .keyPress(let key):
                let normalizedKey = key.lowercased()
                // Return/enter are common for normal navigation/search and should not require confirmation.
                return normalizedKey == "delete" || normalizedKey == "backspace"
            case .keyCombo(let key, let modifiers):
                let normalizedKey = key.lowercased()
                let normalizedModifiers = Set(modifiers.map { $0.lowercased() })
                if normalizedModifiers.contains("command") || normalizedModifiers.contains("cmd") {
                    // Restrict destructive confirmation to high-risk quit/delete combos.
                    return ["q", "backspace", "delete"].contains(normalizedKey)
                }
                return false
            case .typeText(let text):
                let normalizedText = text.lowercased()
                let destructiveKeywords = ["delete", "quit", "close", "send", "submit", "purchase", "install", "rm ", "sudo ", "git reset --hard"]
                return destructiveKeywords.contains(where: { normalizedText.contains($0) })
            case .leftClick, .doubleClick, .rightClick, .scroll(_, _, _), .drag:
                return false
            }
        }
    }

    private func isAffirmativeConfirmation(_ transcript: String) -> Bool {
        let normalizedTranscript = transcript.lowercased()
        let affirmativePhrases = ["yes", "confirm", "do it", "go ahead", "proceed", "run it"]
        return affirmativePhrases.contains(where: { normalizedTranscript.contains($0) })
    }

    private func isNegativeConfirmation(_ transcript: String) -> Bool {
        let normalizedTranscript = transcript.lowercased()
        let negativePhrases = ["no", "cancel", "don't", "do not", "stop", "never mind"]
        return negativePhrases.contains(where: { normalizedTranscript.contains($0) })
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
    you're clicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

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
                guard aiServiceSettings.hasOpenRouterAPIKey else {
                    print("🎯 Onboarding demo skipped: missing OpenRouter API key")
                    return
                }
                let screenCaptures = try await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG()
                guard let cursorScreenCapture = screenCaptures.first else {
                    print("🎯 Onboarding demo: no screen capture")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await openRouterAPI.analyzeImageStreaming(
                    apiKey: aiServiceSettings.openRouterAPIKey,
                    selectedModel: aiServiceSettings.selectedOpenRouterModelID,
                    knownModels: availableOpenRouterModels,
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
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let globalLocation = cursorScreenCapture.globalAppKitPointFromScreenshotPixelCoordinate(
                    screenshotPixelX: clampedX,
                    screenshotPixelY: clampedY
                )
                logComputerUsePixelToGlobalMapping(
                    context: "onboarding_demo_overlay",
                    screenshotPixelX: clampedX,
                    screenshotPixelY: clampedY,
                    targetScreenCapture: cursorScreenCapture,
                    globalPoint: globalLocation
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
