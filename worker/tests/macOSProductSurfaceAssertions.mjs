import { readFileSync } from "node:fs";
import path from "node:path";
import assert from "node:assert/strict";

export function registerMacOSProductSurfaceAssertions({ test, workerRoot }) {
  test("macOS panel keeps first-step Guided Setup as the MVP AHA", () => {
    const panelSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionPanelView.swift"),
      "utf8"
    );
    const panelChromeSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionPanelChromeViews.swift"),
      "utf8"
    );
    const panelAccountAccessSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionPanelAccountAccessView.swift"),
      "utf8"
    );
    const panelMissionWizardSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionPanelMissionWizardViews.swift"),
      "utf8"
    );
    const panelSettingsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionPanelSettingsViews.swift"),
      "utf8"
    );
    const missionDraftSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionPanelMissionDraft.swift"),
      "utf8"
    );
    const panelFormControlsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionPanelFormControls.swift"),
      "utf8"
    );
    const panelSurfaceStylesSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionPanelSurfaceStyles.swift"),
      "utf8"
    );
    const featureSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderProductFeatures.swift"),
      "utf8"
    );
    const panelSurfaceSource = [
      panelSource,
      panelChromeSource,
      panelAccountAccessSource,
      panelMissionWizardSource,
      panelSettingsSource,
    ].join("\n");

    assert.match(featureSource, /case firstStepGuidedSetup = "first_step_guided_setup"/);
    assert.match(featureSource, /case preflightAudit = "preflight_audit"/);
    assert.match(featureSource, /case review72h = "review_72h"/);
    assert.match(featureSource, /availability: \.available/);
    assert.match(featureSource, /availability: \.locked/);
    assert.match(panelSurfaceSource, /Build the right campaign\\nbefore you spend\./);
    assert.match(panelSurfaceSource, /Build from Scratch/);
    assert.match(panelSurfaceSource, /Start with your offer/);
    assert.match(panelSurfaceSource, /What should this campaign do\?/);
    assert.match(panelSurfaceSource, /Who is this for\?/);
    assert.match(panelSurfaceSource, /Set your test limit/);
    assert.match(panelSurfaceSource, /Your campaign path is ready/);
    assert.match(panelSurfaceSource, /Guide Me/);
    assert.match(panelSurfaceSource, /SpiderProductFeatures\.planFeatureDescriptors/);
    assert.match(panelSurfaceSource, /SpiderProductFeatures\.isAvailable\(\.firstStepGuidedSetup\)/);
    assert.match(panelChromeSource, /struct CompanionPanelBrandHeader: View/);
    assert.match(panelChromeSource, /struct CompanionPanelHomePrimaryAction: View/);
    assert.match(panelChromeSource, /struct CompanionPanelPlanCard: View/);
    assert.match(panelAccountAccessSource, /struct CompanionPanelLoginForm: View/);
    assert.match(panelMissionWizardSource, /struct CompanionPanelOfferStepView: View/);
    assert.match(panelMissionWizardSource, /struct CompanionPanelCampaignGoalStepView: View/);
    assert.match(panelMissionWizardSource, /struct CompanionPanelAudienceStepView: View/);
    assert.match(panelMissionWizardSource, /struct CompanionPanelTestLimitStepView: View/);
    assert.match(panelMissionWizardSource, /struct CompanionPanelCampaignReadyStepView: View/);
    assert.match(panelSettingsSource, /struct CompanionPanelSettingsHomeView: View/);
    assert.match(panelSettingsSource, /struct CompanionPanelSettingsGeneralView: View/);
    assert.match(panelSettingsSource, /struct CompanionPanelSettingsPermissionsView: View/);
    assert.match(missionDraftSource, /struct CompanionPanelMissionDraft: Equatable/);
    assert.match(missionDraftSource, /mutating func prefill\(from mission: AdMission\)/);
    assert.match(missionDraftSource, /mutating func adMissionOfferDraft\(\) -> AdMissionOfferDraft/);
    assert.match(panelFormControlsSource, /struct CompanionPanelMultilineField: View/);
    assert.match(panelFormControlsSource, /struct CompanionPanelPriceField: View/);
    assert.match(panelFormControlsSource, /struct CompanionPanelMenuRow: View/);
    assert.match(panelFormControlsSource, /struct CompanionPanelFooterButtons: View/);
    assert.match(panelSurfaceStylesSource, /enum CompanionPanelSurface/);
    assert.match(panelSurfaceStylesSource, /func companionPanelLiquidGlass/);
    assert.match(panelSurfaceStylesSource, /private struct PanelDragHandleView/);
    assert.match(panelSurfaceSource, /CompanionPanelMultilineField/);
    assert.match(panelSurfaceSource, /CompanionPanelFooterButtons/);
    assert.match(panelSurfaceSource, /CompanionPanelSurface\.assetCard/);
    assert.match(panelSource, /@State private var missionDraft = CompanionPanelMissionDraft\(\)/);
    assert.doesNotMatch(panelSource, /@State private var offerInput/);
    assert.doesNotMatch(panelSource, /@State private var audienceInput/);
    assert.doesNotMatch(panelSource, /@State private var ticketInput/);
    assert.doesNotMatch(panelSource, /@State private var totalTestLimitInput/);
    assert.doesNotMatch(panelSource, /@State private var businessGoalInput/);
    assert.doesNotMatch(panelSource, /private var budgetBoundary/);
    assert.doesNotMatch(panelSource, /private func applyTicketFromStoredValue/);
    assert.doesNotMatch(panelSource, /private func assetMultilineField/);
    assert.doesNotMatch(panelSource, /private func assetPriceField/);
    assert.doesNotMatch(panelSource, /private func numericMoneyBinding/);
    assert.doesNotMatch(panelSource, /private func footerButtons/);
    assert.doesNotMatch(panelSource, /private struct PanelDragHandleView/);
    assert.doesNotMatch(panelSource, /Run Preflight|Check before publishing/);
    assert.doesNotMatch(panelSource, /private var settingsSection/);
    assert.doesNotMatch(panelSource, /private var campaignDirectionSection/);
    assert.doesNotMatch(panelSource, /private var artifactSection/);
    assert.doesNotMatch(panelSource, /private var adMissionSummarySection/);
    assert.doesNotMatch(panelSource, /private var footerSection/);
    assert.match(panelSurfaceSource, /Spider won.t set or spend this/);
    assert.match(panelSurfaceSource, /You click\. Spider never spends\./);
    assert.match(panelSurfaceSource, /Permissions/);
    assert.match(panelSurfaceSource, /General/);
    assert.match(panelSurfaceSource, /Voice mode/);
    assert.match(panelSurfaceSource, /Pointer overlay/);
    assert.match(panelSurfaceSource, /Screen guidance/);
    assert.match(panelSurfaceSource, /Ignored apps/);
    assert.match(panelSurfaceSource, /Upgrade to PRO/);
    assert.doesNotMatch(panelSurfaceSource, /Ads Command Center|How can I help you today|Ask me anything/);
  });

  test("macOS account session policy keeps auth and billing rules outside the manager", () => {
    const managerSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionManager.swift"),
      "utf8"
    );
    const accountActionsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionManagerAccountActions.swift"),
      "utf8"
    );
    const guidedSetupActionsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionManagerGuidedSetupActions.swift"),
      "utf8"
    );
    const visionGuideActionsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionManagerVisionGuideActions.swift"),
      "utf8"
    );
    const presentationActionsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionManagerPresentationActions.swift"),
      "utf8"
    );
    const onboardingActionsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionManagerOnboardingActions.swift"),
      "utf8"
    );
    const adMissionActionsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionManagerAdMissionActions.swift"),
      "utf8"
    );
    const permissionActionsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionManagerPermissionActions.swift"),
      "utf8"
    );
    const permissionStateSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionManagerPermissionState.swift"),
      "utf8"
    );
    const cursorActionsSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionManagerCursorActions.swift"),
      "utf8"
    );
    const lifecycleSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionManagerLifecycle.swift"),
      "utf8"
    );
    const guideResponseRecorderSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionGuideResponseRecorder.swift"),
      "utf8"
    );
    const accountSessionPolicySource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "SpiderAccountSessionPolicy.swift"),
      "utf8"
    );
    const screenContentPermissionProbeSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionScreenContentPermissionProbe.swift"),
      "utf8"
    );
    const visionGuideRequestRunnerSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionVisionGuideRequestRunner.swift"),
      "utf8"
    );
    const onboardingDemoGuideRunnerSource = readFileSync(
      path.join(workerRoot, "..", "leanring-buddy", "CompanionOnboardingDemoGuideRunner.swift"),
      "utf8"
    );

    assert.match(accountActionsSource, /extension CompanionManager/);
    assert.match(accountActionsSource, /func submitEmail\(_ email: String\)/);
    assert.match(accountActionsSource, /func refreshLoginStatus\(\)/);
    assert.match(accountActionsSource, /func openCheckout\(\)/);
    assert.match(accountActionsSource, /func openBillingPortal\(\)/);
    assert.match(accountActionsSource, /func logout\(\)/);
    assert.match(accountActionsSource, /func validateAIEntitlementBeforeScreenCapture\(\) async throws/);
    assert.match(accountActionsSource, /spiderAuthClient\.startMagicLinkLogin/);
    assert.match(accountActionsSource, /spiderAuthClient\.createCheckoutSession/);
    assert.match(accountActionsSource, /spiderAuthClient\.createBillingPortalSession/);
    assert.match(accountActionsSource, /spiderAuthClient\.revokeCurrentSession/);
    assert.match(managerSource, /@Published private\(set\) var accountState: SpiderAccountState = \.checking/);
    assert.match(managerSource, /@Published private\(set\) var billingStatusMessage: String\?/);
    assert.match(managerSource, /@Published private\(set\) var isSubmittingLogin = false/);
    assert.match(managerSource, /@Published private\(set\) var isOpeningCheckout = false/);
    assert.match(managerSource, /@Published private\(set\) var isOpeningBillingPortal = false/);
    assert.match(managerSource, /@Published private\(set\) var isLoggingOut = false/);
    assert.match(managerSource, /@Published private\(set\) var hasSubmittedEmail: Bool/);
    assert.match(managerSource, /@Published private\(set\) var loginStatusMessage: String\?/);
    assert.match(permissionStateSource, /extension CompanionManager/);
    assert.match(permissionStateSource, /var allPermissionsGranted: Bool/);
    assert.match(permissionStateSource, /var hasScreenGuidancePermissions: Bool/);
    assert.match(permissionStateSource, /var companionPermissionState: CompanionPermissionState/);
    assert.match(permissionStateSource, /CompanionPermissionPolicy\.screenGuidancePermissionsReady/);
    assert.match(cursorActionsSource, /extension CompanionManager/);
    assert.match(cursorActionsSource, /func setSpiderCursorEnabled\(_ enabled: Bool\)/);
    assert.match(cursorActionsSource, /func showSpiderCursorForGuidedSetupIfPossible\(\)/);
    assert.match(cursorActionsSource, /CompanionInteractionReadinessPolicy\.accountReadiness/);
    assert.match(cursorActionsSource, /CompanionInteractionReadinessPolicy\.screenGuidancePermissionReadiness/);
    assert.match(cursorActionsSource, /overlayWindowManager\.showOverlay/);
    assert.match(cursorActionsSource, /setOverlayVisible\(true\)/);
    assert.doesNotMatch(managerSource, /var allPermissionsGranted: Bool/);
    assert.doesNotMatch(managerSource, /var hasScreenGuidancePermissions: Bool/);
    assert.doesNotMatch(managerSource, /var companionPermissionState: CompanionPermissionState/);
    assert.doesNotMatch(managerSource, /func setSpiderCursorEnabled\(_ enabled: Bool\)/);
    assert.doesNotMatch(managerSource, /func showSpiderCursorForGuidedSetupIfPossible\(\)/);
    assert.match(lifecycleSource, /extension CompanionManager/);
    assert.match(lifecycleSource, /func start\(\)/);
    assert.match(lifecycleSource, /func stop\(\)/);
    assert.match(lifecycleSource, /private func bindVoiceStateObservation\(\)/);
    assert.match(lifecycleSource, /private func bindAudioPowerLevel\(\)/);
    assert.match(lifecycleSource, /private func bindShortcutTransitions\(\)/);
    assert.match(lifecycleSource, /private func handleShortcutTransition/);
    assert.match(lifecycleSource, /private func dismissOnboardingPromptIfVisible\(\)/);
    assert.match(lifecycleSource, /private func summonCompanionFromKeyboardShortcut\(\)/);
    assert.match(lifecycleSource, /CompanionKeyboardShortcutPolicy\.shouldSummonOnRelease/);
    assert.match(lifecycleSource, /setLastTranscript\(finalTranscript\)/);
    assert.match(lifecycleSource, /setCurrentAudioPowerLevel\(powerLevel\)/);
    assert.match(managerSource, /func setLastTranscript\(_ transcript: String\?\)/);
    assert.match(managerSource, /func setCurrentAudioPowerLevel\(_ powerLevel: CGFloat\)/);
    assert.doesNotMatch(managerSource, /func start\(\)/);
    assert.doesNotMatch(managerSource, /func stop\(\)/);
    assert.doesNotMatch(managerSource, /private func bindVoiceStateObservation\(\)/);
    assert.doesNotMatch(managerSource, /private func bindAudioPowerLevel\(\)/);
    assert.doesNotMatch(managerSource, /private func bindShortcutTransitions\(\)/);
    assert.doesNotMatch(managerSource, /private func handleShortcutTransition/);
    assert.doesNotMatch(managerSource, /private func summonCompanionFromKeyboardShortcut\(\)/);
    assert.match(accountActionsSource, /setLoginRequestInFlight\(true\)/);
    assert.match(accountActionsSource, /defer \{ setLoginRequestInFlight\(false\) \}/);
    assert.match(accountActionsSource, /setCheckoutRequestInFlight\(true\)/);
    assert.match(accountActionsSource, /defer \{ setCheckoutRequestInFlight\(false\) \}/);
    assert.match(accountActionsSource, /setBillingPortalRequestInFlight\(true\)/);
    assert.match(accountActionsSource, /defer \{ setBillingPortalRequestInFlight\(false\) \}/);
    assert.match(accountActionsSource, /setLogoutRequestInFlight\(true\)/);
    assert.match(accountActionsSource, /defer \{ setLogoutRequestInFlight\(false\) \}/);
    assert.doesNotMatch(accountActionsSource, /\baccountState\s*=/);
    assert.doesNotMatch(accountActionsSource, /\bbillingStatusMessage\s*=/);
    assert.doesNotMatch(accountActionsSource, /\bisSubmittingLogin\s*=/);
    assert.doesNotMatch(accountActionsSource, /\bisOpeningCheckout\s*=/);
    assert.doesNotMatch(accountActionsSource, /\bisOpeningBillingPortal\s*=/);
    assert.doesNotMatch(accountActionsSource, /\bisLoggingOut\s*=/);
    assert.doesNotMatch(accountActionsSource, /\bhasSubmittedEmail\s*=/);
    assert.doesNotMatch(accountActionsSource, /\bloginStatusMessage\s*=/);
    assert.match(accountSessionPolicySource, /enum SpiderAccountState: Equatable/);
    assert.match(accountSessionPolicySource, /enum SpiderBillingAction/);
    assert.match(accountSessionPolicySource, /struct SpiderAccountStatusResolution: Equatable/);
    assert.match(accountSessionPolicySource, /enum SpiderAccountWorkerErrorResolution: Equatable/);
    assert.match(accountSessionPolicySource, /static func statusResolution/);
    assert.match(accountSessionPolicySource, /static func magicLinkToken/);
    assert.match(accountSessionPolicySource, /queryItems\.count == 1/);
    assert.match(accountSessionPolicySource, /SpiderWorkerTokenValidator\.normalizedDoubleUUIDV4Token/);
    assert.match(accountSessionPolicySource, /static func workerErrorResolution/);
    assert.match(accountSessionPolicySource, /static func billingFailureMessage/);
    assert.match(accountActionsSource, /SpiderAccountSessionPolicy\.statusResolution/);
    assert.match(accountActionsSource, /SpiderAccountSessionPolicy\.magicLinkToken/);
    assert.match(accountActionsSource, /SpiderAccountSessionPolicy\.workerErrorResolution/);
    assert.match(accountActionsSource, /SpiderAccountSessionPolicy\.billingFailureMessage/);
    assert.match(accountActionsSource, /applyAccountStatusResolution/);
    assert.match(screenContentPermissionProbeSource, /enum CompanionScreenContentPermissionProbe/);
    assert.match(screenContentPermissionProbeSource, /ScreenCaptureKit/);
    assert.match(screenContentPermissionProbeSource, /SCScreenshotManager\.captureImage/);
    assert.match(screenContentPermissionProbeSource, /width: image\.width/);
    assert.match(screenContentPermissionProbeSource, /height: image\.height/);
    assert.match(permissionActionsSource, /extension CompanionManager/);
    assert.match(permissionActionsSource, /func refreshAllPermissions\(\)/);
    assert.match(permissionActionsSource, /func requestScreenContentPermission\(\)/);
    assert.match(permissionActionsSource, /func startPermissionPolling\(\)/);
    assert.match(permissionActionsSource, /CompanionScreenContentPermissionProbe\.run/);
    assert.match(permissionActionsSource, /CompanionPermissionTelemetryRecorder\.recordScreenContentCaptureProbe/);
    assert.match(permissionActionsSource, /setScreenContentRequestInFlight\(true\)/);
    assert.match(permissionActionsSource, /setPermissionPollingTimer\(Timer\.scheduledTimer/);
    assert.match(managerSource, /func setAccessibilityPermission\(_ granted: Bool\)/);
    assert.match(managerSource, /func setScreenContentPermission\(_ granted: Bool\)/);
    assert.match(managerSource, /func setScreenContentRequestInFlight\(_ inFlight: Bool\)/);
    assert.doesNotMatch(managerSource, /CompanionScreenContentPermissionProbe\.run/);
    assert.doesNotMatch(managerSource, /func requestScreenContentPermission\(\)/);
    assert.doesNotMatch(managerSource, /func startPermissionPolling\(\)/);
    assert.doesNotMatch(managerSource, /import ScreenCaptureKit/);
    assert.doesNotMatch(managerSource, /SCShareableContent\.excludingDesktopWindows/);
    assert.doesNotMatch(managerSource, /SCScreenshotManager\.captureImage/);
    assert.doesNotMatch(managerSource, /func submitEmail\(_ email: String\)/);
    assert.doesNotMatch(managerSource, /func openCheckout\(\)/);
    assert.doesNotMatch(managerSource, /func openBillingPortal\(\)/);
    assert.doesNotMatch(managerSource, /func logout\(\)/);
    assert.doesNotMatch(managerSource, /createCheckoutSession/);
    assert.doesNotMatch(managerSource, /createBillingPortalSession/);
    assert.doesNotMatch(managerSource, /revokeCurrentSession/);
    assert.doesNotMatch(managerSource, /func magicLinkToken\(/);
    assert.doesNotMatch(managerSource, /private enum BillingAction/);

    assert.match(guidedSetupActionsSource, /extension CompanionManager/);
    assert.match(guidedSetupActionsSource, /func openConfiguredAdPlatformAndStartGuidedSetup\(\)/);
    assert.match(guidedSetupActionsSource, /func requestGuidedSetupStepFromCurrentScreen\(\)/);
    assert.match(guidedSetupActionsSource, /func scheduleInitialGuidedSetupStep\(\)/);
    assert.match(guidedSetupActionsSource, /func runScheduledGuidedSetupStep\(\)/);
    assert.match(guidedSetupActionsSource, /func handleGuidedSetupPollResult\(/);
    assert.match(guidedSetupActionsSource, /guidedSetupPollScheduler/);
    assert.match(guidedSetupActionsSource, /GuidedSetupPollingPolicy/);
    assert.match(guidedSetupActionsSource, /GuidedSetupPromptComposer/);
    assert.match(guidedSetupActionsSource, /GuidedSetupSession\(platformId:/);
    assert.match(guidedSetupActionsSource, /AdMissionLifecyclePolicy\.guidedSetupStarted/);
    assert.match(guidedSetupActionsSource, /SpiderAnalytics\.trackGuidedSetupStarted/);
    assert.match(guidedSetupActionsSource, /GroundingTelemetryRecorder\.recordOutcomeEvaluated/);
    assert.doesNotMatch(managerSource, /func openConfiguredAdPlatformAndStartGuidedSetup\(\)/);
    assert.doesNotMatch(managerSource, /func requestGuidedSetupStepFromCurrentScreen\(\)/);
    assert.doesNotMatch(managerSource, /func scheduleInitialGuidedSetupStep\(\)/);
    assert.doesNotMatch(managerSource, /func runScheduledGuidedSetupStep\(\)/);
    assert.doesNotMatch(managerSource, /func handleGuidedSetupPollResult\(/);

    assert.match(presentationActionsSource, /extension CompanionManager/);
    assert.match(presentationActionsSource, /func handleVisionClientError\(_ error: OpenAIVisionGuideClientError\)/);
    assert.match(presentationActionsSource, /func clearDetectedElementLocation\(\)/);
    assert.match(presentationActionsSource, /func clearGuidanceStatusBubble\(\)/);
    assert.match(presentationActionsSource, /func applyGuidePoint\(/);
    assert.match(presentationActionsSource, /func ensureProductFeatureAvailable\(_ feature: SpiderProductFeature\)/);
    assert.match(presentationActionsSource, /func speakSystemText\(_ text: String\)/);
    assert.match(presentationActionsSource, /func handleInteractionReadiness\(/);
    assert.match(presentationActionsSource, /CompanionGuidePointOverlayPresenter\.application/);
    assert.match(presentationActionsSource, /CompanionSpeechPlaybackController\.Callbacks/);
    assert.doesNotMatch(managerSource, /func handleVisionClientError\(/);
    assert.doesNotMatch(managerSource, /func clearGuidanceStatusBubble\(\)/);
    assert.doesNotMatch(managerSource, /func applyGuidePoint\(/);
    assert.doesNotMatch(managerSource, /func speakSystemText\(/);
    assert.doesNotMatch(managerSource, /func handleInteractionReadiness\(/);

    assert.match(onboardingActionsSource, /extension CompanionManager/);
    assert.match(onboardingActionsSource, /func triggerOnboarding\(\)/);
    assert.match(onboardingActionsSource, /func replayOnboarding\(\)/);
    assert.match(onboardingActionsSource, /func setupOnboardingVideo\(\)/);
    assert.match(onboardingActionsSource, /func performOnboardingDemoInteraction\(\)/);
    assert.match(onboardingActionsSource, /CompanionOnboardingDemoGuideRunner\.run/);
    assert.match(onboardingActionsSource, /SpiderAnalytics\.trackOnboardingStarted/);
    assert.match(onboardingActionsSource, /SpiderAnalytics\.trackOnboardingDemoTriggered/);
    assert.doesNotMatch(managerSource, /func triggerOnboarding\(\)/);
    assert.doesNotMatch(managerSource, /func replayOnboarding\(\)/);
    assert.doesNotMatch(managerSource, /func setupOnboardingVideo\(\)/);
    assert.doesNotMatch(managerSource, /func performOnboardingDemoInteraction\(\)/);

    assert.match(adMissionActionsSource, /extension CompanionManager/);
    assert.match(adMissionActionsSource, /func saveAdMissionIfChanged\(_ updatedMission: AdMission\)/);
    assert.match(adMissionActionsSource, /func resetAdMission\(\)/);
    assert.match(adMissionActionsSource, /func startAdMissionFromOffer\(_ draft: AdMissionOfferDraft\)/);
    assert.match(adMissionActionsSource, /func requestPreflightAuditFromCurrentScreen\(\)/);
    assert.match(adMissionActionsSource, /func request72hReviewFromCurrentScreen\(\)/);
    assert.match(adMissionActionsSource, /func markAdMissionAsManuallyPublished\(\)/);
    assert.match(adMissionActionsSource, /AdMissionLifecyclePolicy\.preflightAuditRequested/);
    assert.match(adMissionActionsSource, /AdMissionLifecyclePolicy\.manuallyPublished/);
    assert.match(adMissionActionsSource, /Never suggest automatic pause, budget increase, billing action, or performance guarantees/);
    assert.match(adMissionActionsSource, /stop before any publish, spend, budget, billing, pause, or delete action/);
    assert.doesNotMatch(adMissionActionsSource, /func persistArtifact\(_ artifact: SpiderArtifact\)/);
    assert.doesNotMatch(adMissionActionsSource, /func persistAdMissionUpdate\(_ missionUpdate: AdMissionUpdate\)/);
    assert.doesNotMatch(adMissionActionsSource, /func persistDecisionMemoryUpdate\(_ decisionMemoryUpdate: String\)/);
    assert.doesNotMatch(adMissionActionsSource, /AdMissionLocalPersistence\.persistArtifact/);
    assert.doesNotMatch(adMissionActionsSource, /AdMissionLocalPersistence\.persistAdMissionUpdate/);
    assert.match(guideResponseRecorderSource, /struct CompanionGuideResponseRecorder/);
    assert.match(guideResponseRecorderSource, /private var conversationHistory = SpiderGuideConversationHistory\(\)/);
    assert.match(guideResponseRecorderSource, /AdMissionLocalPersistence\.persistArtifact/);
    assert.match(guideResponseRecorderSource, /AdMissionLocalPersistence\.persistAdMissionUpdate/);
    assert.match(guideResponseRecorderSource, /AdMissionLocalPersistence\.persistDecisionMemoryUpdate/);
    assert.match(guideResponseRecorderSource, /SpiderAnalytics\.trackAIResponseReceived\(responseCharacterCount: guideResponse\.displayText\.count\)/);
    assert.match(managerSource, /func setAdMissionState\(_ mission: AdMission\)/);
    assert.match(managerSource, /func clearAdMissionSessionContext\(\)/);
    assert.match(managerSource, /private var guideResponseRecorder = CompanionGuideResponseRecorder\(\)/);
    assert.match(visionGuideRequestRunnerSource, /enum CompanionVisionGuideRequestRunner/);
    assert.match(visionGuideRequestRunnerSource, /struct CompanionVisionGuideRequestResult/);
    assert.match(visionGuideRequestRunnerSource, /CompanionScreenCaptureUtility\.captureAllScreensAsJPEG/);
    assert.match(visionGuideRequestRunnerSource, /CompanionGuideRequestContextBuilder\.build/);
    assert.match(visionGuideRequestRunnerSource, /guideClient\.guide/);
    assert.match(visionGuideRequestRunnerSource, /GroundingTelemetryRecorder\.recordFrameAnalyzed/);
    assert.match(visionGuideRequestRunnerSource, /SpiderAnalytics\.trackGuideScreenClassified/);
    assert.match(visionGuideActionsSource, /extension CompanionManager/);
    assert.match(visionGuideActionsSource, /func sendTranscriptToSpiderGuideWithScreenshot\(/);
    assert.match(visionGuideActionsSource, /CompanionVisionGuideRequestRunner\.run/);
    assert.match(onboardingDemoGuideRunnerSource, /enum CompanionOnboardingDemoGuideRunner/);
    assert.match(onboardingDemoGuideRunnerSource, /struct CompanionOnboardingDemoGuideResult/);
    assert.match(onboardingDemoGuideRunnerSource, /CompanionOnboardingDemoGuidePrompt/);
    assert.match(onboardingDemoGuideRunnerSource, /Do not publish or change spend/);
    assert.match(onboardingDemoGuideRunnerSource, /CompanionScreenCaptureUtility\.captureAllScreensAsJPEG/);
    assert.match(onboardingDemoGuideRunnerSource, /first\(where: \{ \$0\.isCursorScreen \}\)/);
    assert.match(onboardingDemoGuideRunnerSource, /guideClient\.guide/);
    assert.match(onboardingDemoGuideRunnerSource, /GroundingTelemetryRecorder\.recordFrameAnalyzed/);
    assert.match(onboardingDemoGuideRunnerSource, /CompanionGuidePointEvaluator\.evaluate/);
    assert.match(onboardingDemoGuideRunnerSource, /sensorFusionRejectionStyle: \.genericContradiction/);
    assert.match(onboardingActionsSource, /CompanionOnboardingDemoGuideRunner\.run/);
    assert.doesNotMatch(managerSource, /single most useful setup issue/);
    assert.doesNotMatch(managerSource, /CompanionScreenCaptureUtility\.captureAllScreensAsJPEG/);
    assert.match(managerSource, /var guideConversationTurns:/);
    assert.match(managerSource, /func recordGuideResponse\(/);
    assert.match(visionGuideActionsSource, /conversationHistory: guideConversationTurns/);
    assert.match(visionGuideActionsSource, /recordGuideResponse\(guideResponse, userTranscript: transcript\)/);
    assert.doesNotMatch(managerSource, /CompanionVisionGuideRequestRunner\.run/);
    assert.doesNotMatch(managerSource, /conversationHistory: guideResponseRecorder\.conversationTurns/);
    assert.doesNotMatch(managerSource, /CompanionGuideRequestContextBuilder\.build/);
    assert.doesNotMatch(managerSource, /func persistArtifact\(_ artifact: SpiderArtifact\)/);
    assert.doesNotMatch(managerSource, /func persistAdMissionUpdate\(_ missionUpdate: AdMissionUpdate\)/);
    assert.doesNotMatch(managerSource, /func persistDecisionMemoryUpdate\(_ decisionMemoryUpdate: String\)/);
    assert.doesNotMatch(managerSource, /AdMissionLocalPersistence\.persistArtifact/);
    assert.doesNotMatch(managerSource, /SpiderAnalytics\.trackAIResponseReceived/);
    assert.doesNotMatch(managerSource, /func resetAdMission\(\)/);
    assert.doesNotMatch(managerSource, /func startAdMissionFromOffer\(_ draft: AdMissionOfferDraft\)/);
    assert.doesNotMatch(managerSource, /func requestPreflightAuditFromCurrentScreen\(\)/);
    assert.doesNotMatch(managerSource, /func request72hReviewFromCurrentScreen\(\)/);
    assert.doesNotMatch(managerSource, /func markAdMissionAsManuallyPublished\(\)/);
  });
}
