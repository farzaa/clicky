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
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false
    @Published private(set) var isRequestingScreenContent = false
    @Published private(set) var adMission: AdMission = AdMissionStore.load()
    @Published private(set) var accountState: SpiderAccountState = .checking
    @Published private(set) var billingStatusMessage: String?
    @Published private(set) var isSubmittingLogin = false
    @Published private(set) var isOpeningCheckout = false
    @Published private(set) var isOpeningBillingPortal = false
    @Published private(set) var isLoggingOut = false

    /// Screen location (global AppKit coords) of a detected UI element Spider
    /// should fly to and point at. Parsed from the visual guide response;
    /// observed by SpiderCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so SpiderCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// SpiderCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?
    /// Short visible UI label for the target Spider is pointing at.
    @Published var detectedElementPointLabel: String?
    /// Short non-sensitive reason linking this target to the selected mission.
    @Published var detectedElementMissionAlignment: String?
    /// Changes on every accepted target so the overlay replays even if coordinates repeat.
    @Published var detectedElementTargetRevision = UUID()
    @Published var guidanceStatusText: String = ""
    @Published var guidanceStatusOpacity: Double = 0.0

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    lazy var spiderVisionGuideClient = OpenAIVisionGuideClient()
    private lazy var openAIRealtimeVoiceClient = OpenAIRealtimeVoiceClient()
    let spiderAuthClient = SpiderAuthClient()
    let onboardingMusicController = CompanionOnboardingMusicController()
    let onboardingVideoController = CompanionOnboardingVideoController()
    let onboardingPromptController = CompanionOnboardingPromptController()
    let guidanceStatusBubbleController = CompanionGuidanceStatusBubbleController()
    private let systemSpeechPlayer = CompanionSystemSpeechPlayer()
    lazy var speechPlaybackController = CompanionSpeechPlaybackController(
        realtimeVoiceClient: openAIRealtimeVoiceClient,
        systemSpeechPlayer: systemSpeechPlayer
    )
    let transientOverlayHideController = CompanionTransientOverlayHideController()
    let guidedSetupPollScheduler = GuidedSetupPollScheduler()

    private var guideResponseRecorder = CompanionGuideResponseRecorder()

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    var currentResponseTask: Task<Void, Never>?

    var shortcutTransitionCancellable: AnyCancellable?
    var voiceStateCancellable: AnyCancellable?
    var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    var guidedSetupSession: GuidedSetupSession?
    var keyboardShortcutPressedAt: Date?
    var keyboardShortcutDidStartDictation = false
    var isVisionGuideRequestInFlight = false

    /// Whether the Spider cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// User preference for whether the Spider cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isSpiderCursorEnabled: Bool = {
        if UserDefaults.standard.object(forKey: "isSpiderCursorEnabled") != nil {
            return UserDefaults.standard.bool(forKey: "isSpiderCursorEnabled")
        }
        return true
    }()

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published private(set) var hasSubmittedEmail: Bool = CompanionAccountLocalStateStore.loadHasSubmittedEmail()
    @Published private(set) var loginStatusMessage: String?

    // MARK: - Account Action State Mutation

    func setVoiceState(_ state: CompanionVoiceState) {
        voiceState = state
    }

    func setLastTranscript(_ transcript: String?) {
        lastTranscript = transcript
    }

    func setCurrentAudioPowerLevel(_ powerLevel: CGFloat) {
        currentAudioPowerLevel = powerLevel
    }

    func setOverlayVisible(_ visible: Bool) {
        isOverlayVisible = visible
    }

    // MARK: - Permission State Mutation

    func setAccessibilityPermission(_ granted: Bool) {
        hasAccessibilityPermission = granted
    }

    func setScreenRecordingPermission(_ granted: Bool) {
        hasScreenRecordingPermission = granted
    }

    func setMicrophonePermission(_ granted: Bool) {
        hasMicrophonePermission = granted
    }

    func setScreenContentPermission(_ granted: Bool) {
        hasScreenContentPermission = granted
    }

    func setScreenContentRequestInFlight(_ inFlight: Bool) {
        isRequestingScreenContent = inFlight
    }

    func setPermissionPollingTimer(_ timer: Timer?) {
        accessibilityCheckTimer = timer
    }

    func clearPermissionPollingTimer() {
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    // MARK: - Account Action State Mutation

    func setAccountState(_ state: SpiderAccountState) {
        accountState = state
    }

    func setLoginStatusMessage(_ message: String?) {
        loginStatusMessage = message
    }

    func setBillingStatusMessage(_ message: String?) {
        billingStatusMessage = message
    }

    func setLoginRequestInFlight(_ inFlight: Bool) {
        isSubmittingLogin = inFlight
    }

    func setCheckoutRequestInFlight(_ inFlight: Bool) {
        isOpeningCheckout = inFlight
    }

    func setBillingPortalRequestInFlight(_ inFlight: Bool) {
        isOpeningBillingPortal = inFlight
    }

    func setLogoutRequestInFlight(_ inFlight: Bool) {
        isLoggingOut = inFlight
    }

    func setSubmittedEmailState(_ submitted: Bool) {
        hasSubmittedEmail = submitted
        CompanionAccountLocalStateStore.persistHasSubmittedEmail(submitted)
    }

    // MARK: - Ad Mission Action State Mutation

    func setAdMissionState(_ mission: AdMission) {
        adMission = mission
    }

    func clearAdMissionSessionContext() {
        guideResponseRecorder.removeAllConversationContext()
        lastTranscript = nil
        clearDetectedElementLocation()
    }

    var guideConversationTurns: [(userTranscript: String, assistantResponse: String)] {
        guideResponseRecorder.conversationTurns
    }

    func recordGuideResponse(_ guideResponse: SpiderGuideResponse, userTranscript: String) {
        guideResponseRecorder.record(
            guideResponse,
            userTranscript: userTranscript,
            adMission: &adMission
        )
    }

    func currentPlatformContextForGuide() -> SpiderPlatformContext? {
        AdPlatformGuideConfiguration.resolve(adMission: adMission).platformContext
    }

    func currentPlatformIdForGuide() -> SpiderAdPlatformID {
        AdPlatformGuideConfiguration.resolve(adMission: adMission).platformId
    }

    var configuredAdPlatformDisplayName: String {
        AdPlatformGuideConfiguration.resolve(adMission: adMission).displayName
    }

    func configuredAdPlatformURLString() -> String {
        AdPlatformGuideConfiguration.resolve(adMission: adMission).launchURLString
    }

}
