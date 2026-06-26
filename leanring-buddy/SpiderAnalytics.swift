//
//  SpiderAnalytics.swift
//  leanring-buddy
//
//  Privacy-safe analytics shim. It deliberately never sends transcripts, AI
//  responses, screenshots, email addresses, or prompts.
//

import Foundation

enum SpiderPermissionTelemetryName: String, CaseIterable, Equatable {
    case accessibility = "accessibility"
    case screenRecording = "screen_recording"
    case microphone = "microphone"
    case screenContent = "screen_content"
}

enum SpiderAnalytics {
    static func configure() {}

    static func trackAppOpened() {
        logMetric("app_opened")
    }

    static func trackOnboardingStarted() {
        logMetric("onboarding_started")
    }

    static func trackOnboardingReplayed() {
        logMetric("onboarding_replayed")
    }

    static func trackOnboardingVideoCompleted() {
        logMetric("onboarding_video_completed")
    }

    static func trackOnboardingDemoTriggered() {
        logMetric("onboarding_demo_triggered")
    }

    static func trackAllPermissionsGranted() {
        logMetric("all_permissions_granted")
    }

    static func trackPermissionGranted(_ permission: SpiderPermissionTelemetryName) {
        logMetric("permission_granted:\(permission.rawValue)")
    }

    static func trackPushToTalkStarted() {
        logMetric("push_to_talk_started")
    }

    static func trackPushToTalkReleased() {
        logMetric("push_to_talk_released")
    }

    static func trackUserMessageSent(transcriptCharacterCount: Int) {
        logMetric("user_message_sent:length=\(transcriptCharacterCount)")
    }

    static func trackAIResponseReceived(responseCharacterCount: Int) {
        logMetric("ai_response_received:length=\(responseCharacterCount)")
    }

    static func trackElementPointed() {
        logMetric("element_pointed")
    }

    static func trackGuideScreenClassified(
        screenState: SpiderGuideScreenState,
        confidence: SpiderGuideConfidence
    ) {
        logMetric("guide_screen_classified:state=\(screenState.rawValue):confidence=\(confidence.rawValue)")
    }

    static func trackGuidePointRejected(reason: SpiderGuidePointRejectionReason) {
        logMetric("guide_point_rejected:\(reason.rawValue)")
    }

    static func trackGuidePointOutcome(status: GuidedPointOutcomeStatus) {
        logMetric("guide_point_outcome:\(status.rawValue)")
    }

    static func trackGuideLoadingReclassification() {
        logMetric("guide_loading_reclassification")
    }

    static func trackGuideUnknownScreen() {
        logMetric("guide_unknown_screen")
    }

    static func trackAdMissionCreated() {
        logMetric("ad_mission_created")
    }

    static func trackCampaignPlanGenerated() {
        logMetric("campaign_plan_generated")
    }

    static func trackGuidedSetupStarted() {
        trackFeatureStarted(.firstStepGuidedSetup)
    }

    static func trackPreflightAuditStarted() {
        trackFeatureStarted(.preflightAudit)
    }

    static func trackReview72hStarted() {
        trackFeatureStarted(.review72h)
    }

    static func trackFeatureStarted(_ feature: SpiderProductFeature) {
        guard SpiderProductFeatures.isAvailable(feature) else {
            trackLockedFeatureRequested(feature)
            return
        }

        logMetric("feature_started_\(feature.rawValue)")
    }

    static func trackLockedFeatureRequested(_ feature: SpiderProductFeature) {
        logMetric("locked_feature_requested_\(feature.rawValue)")
    }

    static func trackResponseError() {
        logMetric("response_error")
    }

    static func trackTTSError() {
        logMetric("tts_error")
    }

    static func logMetric(_ name: String) {
        #if DEBUG
        print("Spider metric: \(name)")
        #endif
    }
}
