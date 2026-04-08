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

    func setSelectedModel(_ model: String) {
        aiServiceSettings.saveSelectedOpenRouterModelID(model)
    }

    func setShowOnlyWebEnabledModels(_ showOnlyWebEnabledModels: Bool) {
        aiServiceSettings.saveShowOnlyWebEnabledModels(showOnlyWebEnabledModels)
    }

    func setComputerUseEnabled(_ isComputerUseEnabled: Bool) {
        aiServiceSettings.saveComputerUseEnabled(isComputerUseEnabled)
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
        conversationHistory.removeAll()
        hasConversationHistory = false
        pendingDestructiveActionPlan = nil
        print("🧠 Conversation history cleared by user.")
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
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - speak in the same language as the user's latest message unless they ask you to switch. do not force english.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - never narrate internal metadata or control syntax in the spoken text. do not say things like actions json, point tag, coordinates, x/y values, screen numbers, cursor metadata, or execution metadata out loud.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - when the user asks for current events, recent updates, live pricing, version changes, or anything time-sensitive, use the web_search tool first and ground your answer in those results.
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

    private static let companionVoiceResponseSystemPromptWhenComputerUseEnabled = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - speak in the same language as the user's latest message unless they ask you to switch. do not force english.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - never narrate internal metadata or control syntax in the spoken text. do not say things like actions json, point tag, coordinates, x/y values, screen numbers, cursor metadata, or execution metadata out loud.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - when the user asks for current events, recent updates, live pricing, version changes, or anything time-sensitive, use the web_search tool first and ground your answer in those results.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    computer use mode:
    - computer use is enabled. the app will execute your json actions locally. you are not allowed to only tell the user to click — you must emit the machine actions yourself.
    - critical: if the user asks you to click, double-click, right-click, type, press keys, scroll, or drag on screen, you MUST include a non-empty [ACTIONS_JSON] block before your [POINT:...] tag with at least one action that performs that step. pointing alone is never enough for those requests. do not answer with only "you should click" or "click that tab" without the actions json.
    - only use [ACTIONS_JSON]{"actions":[]}[/ACTIONS_JSON] when the user is not asking for any on-screen control (pure explanation, general knowledge, or no specific ui step).
    - prefer concrete operational guidance in speech, but the real click/type must appear in actions json.
    - if a request maps to a visible ui workflow, choose a specific next interaction target, put left_click (or type_text, etc.) in actions json, then point to the same target in [POINT:...] for the blue cursor.
    - browser tab bars are easy to get wrong: read the exact tab title visible in the screenshot, place x,y at the horizontal center of that title (not an adjacent tab), and use the same integers for left_click in [ACTIONS_JSON] and for [POINT:...] (same screen number too).
    - if there are multiple monitor images, only use coordinates from the image that actually shows the target ui; set "screen" and :screenN to that monitor’s index from the screenshot labels — wrong screen index shifts x and y even when pixel math is right.
    - never claim you already clicked, typed, or completed a step unless that action is confirmed by visible state in the screenshots.
    - when the task cannot be confirmed from screenshots, still emit the best-effort actions json for the next likely step if the user asked for control; say you're trying that step in speech.
    - include an actions block before your [POINT:...] tag with exact json in this format:
      [ACTIONS_JSON]{"actions":[{"type":"left_click","x":123,"y":456},{"type":"type_text","text":"hello"},{"type":"key_combo","key":"k","modifiers":["command"]},{"type":"scroll","deltaX":0,"deltaY":-6},{"type":"drag","startX":300,"startY":500,"endX":900,"endY":500},{"type":"right_click","x":444,"y":222},{"type":"double_click","x":444,"y":222},{"type":"key_press","key":"return"}]}[/ACTIONS_JSON]
    - coordinates in the actions block use the same screenshot pixel coordinate system as [POINT:...], with optional "screen":N for non-primary screenshots.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific ui element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    private var activeCompanionVoiceSystemPrompt: String {
        if isComputerUseEnabled {
            return Self.companionVoiceResponseSystemPromptWhenComputerUseEnabled
        }
        return Self.companionVoiceResponseSystemPrompt
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

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                guard aiServiceSettings.hasOpenRouterAPIKey else {
                    throw NSError(domain: "CompanionManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing OpenRouter API key. Add it in Settings."])
                }

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
                        return
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
                    // Transcript diverged from confirmation flow, so discard old pending action.
                    self.pendingDestructiveActionPlan = nil
                }

                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

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

                let shouldSkipOpenRouterWebSearchAugmentation =
                    isComputerUseEnabled && Self.userTranscriptImpliesComputerControlRequest(transcript)

                var (fullResponseText, _) = try await openRouterAPI.analyzeImageStreaming(
                    apiKey: aiServiceSettings.openRouterAPIKey,
                    selectedModel: aiServiceSettings.selectedOpenRouterModelID,
                    knownModels: availableOpenRouterModels,
                    images: labeledImages,
                    systemPrompt: activeCompanionVoiceSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    forceDisableWebSearchAugmentation: shouldSkipOpenRouterWebSearchAugmentation,
                    onTextChunk: { _ in
                        // No streaming text display — spinner stays until TTS plays
                    }
                )

                guard !Task.isCancelled else { return }

                var parsedAssistantResponse = parseAssistantResponse(from: fullResponseText)

                if isComputerUseEnabled,
                   canExecuteComputerUseAction(),
                   Self.userTranscriptImpliesComputerControlRequest(transcript) {
                    let missingOrEmptyActions =
                        !parsedAssistantResponse.didMatchActionsJSONDelimiters
                        || parsedAssistantResponse.actionInstructions.isEmpty
                    if missingOrEmptyActions {
                        (fullResponseText, _) = try await openRouterAPI.analyzeImageStreaming(
                            apiKey: aiServiceSettings.openRouterAPIKey,
                            selectedModel: aiServiceSettings.selectedOpenRouterModelID,
                            knownModels: availableOpenRouterModels,
                            images: labeledImages,
                            systemPrompt: activeCompanionVoiceSystemPrompt,
                            conversationHistory: historyForAPI,
                            userPrompt: transcript + Self.computerUseRetryUserPromptSuffix,
                            forceDisableWebSearchAugmentation: shouldSkipOpenRouterWebSearchAugmentation,
                            onTextChunk: { _ in
                                // No streaming text display — spinner stays until TTS plays
                            }
                        )
                        guard !Task.isCancelled else { return }
                        parsedAssistantResponse = parseAssistantResponse(from: fullResponseText)
                    }
                }
                var spokenText = parsedAssistantResponse.spokenText
                let parseResult = parsedAssistantResponse.pointingResult
                let mergedComputerUseActionInstructions = computerUseActionInstructionsByMergingPointTagIfUnambiguous(
                    actionInstructions: parsedAssistantResponse.actionInstructions,
                    pointingParseResult: parseResult,
                    screenCaptures: screenCaptures
                )
                let resolvedComputerUseActions = resolveComputerUseActions(
                    from: mergedComputerUseActionInstructions,
                    using: screenCaptures
                )

                var didExecuteComputerUseActionsSuccessfully = false

                if isComputerUseEnabled {
                    if resolvedComputerUseActions.isEmpty,
                       Self.userTranscriptImpliesComputerControlRequest(transcript) {
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
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
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

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))
                hasConversationHistory = !conversationHistory.isEmpty

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }
                hasConversationHistory = !conversationHistory.isEmpty

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await elevenLabsTTSClient.speakText(
                            spokenText,
                            apiKey: aiServiceSettings.elevenLabsAPIKey,
                            voiceID: aiServiceSettings.elevenLabsVoiceID
                        )
                        // speakText returns after player.play() — audio is now playing
                        voiceState = .responding
                    } catch {
                        print("⚠️ ElevenLabs TTS error: \(error)")
                        speakErrorWithSystemSpeechSynthesizer(error: error, failureStage: .textToSpeech)
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                print("⚠️ Companion response error: \(error)")
                speakErrorWithSystemSpeechSynthesizer(error: error, failureStage: .responsePipeline)
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

    /// Speaks using macOS system TTS when ElevenLabs playback fails or the main
    /// pipeline errors. Uses NSSpeechSynthesizer so something is still audible.
    private func speakErrorWithSystemSpeechSynthesizer(
        error: Error,
        failureStage: CompanionSystemSpeechFailureStage
    ) {
        let utterance = systemSpeechUtterance(for: error, failureStage: failureStage)
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    // MARK: - Computer Use Action Parsing

    struct ParsedAssistantResponse {
        let spokenText: String
        let pointingResult: PointingParseResult
        let actionInstructions: [ComputerUseActionInstruction]
        let didMatchActionsJSONDelimiters: Bool
    }

    private struct ComputerUseActionEnvelope: Decodable {
        let actions: [ComputerUseActionInstruction]
    }

    private func parseAssistantResponse(from fullResponseText: String) -> ParsedAssistantResponse {
        let actionParseResult = Self.parseComputerUseActionsBlock(from: fullResponseText)
        let pointingResult = Self.parsePointingCoordinates(from: actionParseResult.textWithoutActionsBlock)
        return ParsedAssistantResponse(
            spokenText: pointingResult.spokenText,
            pointingResult: pointingResult,
            actionInstructions: actionParseResult.actionInstructions,
            didMatchActionsJSONDelimiters: actionParseResult.didMatchActionsJSONDelimiters
        )
    }

    private static func parseComputerUseActionsBlock(
        from responseText: String
    ) -> (
        textWithoutActionsBlock: String,
        actionInstructions: [ComputerUseActionInstruction],
        didMatchActionsJSONDelimiters: Bool
    ) {
        let pattern = #"\[ACTIONS_JSON\](\{[\s\S]*?\})\[/ACTIONS_JSON\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)),
              let jsonRange = Range(match.range(at: 1), in: responseText),
              let blockRange = Range(match.range(at: 0), in: responseText) else {
            return (responseText, [], false)
        }

        let jsonString = String(responseText[jsonRange])
        let actionInstructions: [ComputerUseActionInstruction] = {
            guard let jsonData = jsonString.data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(ComputerUseActionEnvelope.self, from: jsonData) else {
                return []
            }
            return envelope.actions
        }()

        var textWithoutActionsBlock = responseText
        textWithoutActionsBlock.removeSubrange(blockRange)
        textWithoutActionsBlock = textWithoutActionsBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        return (textWithoutActionsBlock, actionInstructions, true)
    }

    /// True when the user is asking for on-screen control (click, type, etc.), not pure Q&A.
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

    /// When the model emits both `[POINT:...]` and `[ACTIONS_JSON]` with a single click action,
    /// use the point tag as the source of truth so the overlay and HID click stay aligned.
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
        let singleSpatialClickTypes: Set<String> = ["left_click", "double_click", "right_click"]
        guard singleSpatialClickTypes.contains(normalizedType) else {
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
                "🖱️ Computer use: [POINT:...] overrides [ACTIONS_JSON] for single click — " +
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
                let deltaX = actionInstruction.deltaX ?? 0
                let deltaY = actionInstruction.deltaY ?? 0
                return .scroll(deltaX: deltaX, deltaY: deltaY)
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
            case .rightClick:
                return true
            case .keyPress(let key):
                let normalizedKey = key.lowercased()
                return normalizedKey == "delete" || normalizedKey == "backspace" || normalizedKey == "return" || normalizedKey == "enter"
            case .keyCombo(let key, let modifiers):
                let normalizedKey = key.lowercased()
                let normalizedModifiers = Set(modifiers.map { $0.lowercased() })
                if normalizedModifiers.contains("command") || normalizedModifiers.contains("cmd") {
                    return ["q", "w", "r", "backspace", "delete", "return", "enter"].contains(normalizedKey)
                }
                return false
            case .typeText(let text):
                let normalizedText = text.lowercased()
                let destructiveKeywords = ["delete", "quit", "close", "send", "submit", "purchase", "install", "rm ", "sudo ", "git reset --hard"]
                return destructiveKeywords.contains(where: { normalizedText.contains($0) })
            case .leftClick, .doubleClick, .scroll, .drag:
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
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
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
