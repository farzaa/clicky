//
//  ClickyAnalytics.swift
//  leanring-buddy
//
//  Analytics were intentionally disabled in this fork — no usage data,
//  transcripts, or AI responses are sent anywhere. All functions remain
//  as no-ops so existing call sites compile unchanged.
//

import Foundation

enum ClickyAnalytics {

    // MARK: - Setup

    static func configure() {}

    // MARK: - App Lifecycle

    static func trackAppOpened() {}

    // MARK: - Onboarding

    static func trackOnboardingStarted() {}

    static func trackOnboardingReplayed() {}

    static func trackOnboardingVideoCompleted() {}

    static func trackOnboardingDemoTriggered() {}

    // MARK: - Permissions

    static func trackAllPermissionsGranted() {}

    static func trackPermissionGranted(permission: String) {}

    // MARK: - Voice Interaction

    static func trackPushToTalkStarted() {}

    static func trackPushToTalkReleased() {}

    static func trackUserMessageSent(transcript: String) {}

    static func trackAIResponseReceived(response: String) {}

    static func trackElementPointed(elementLabel: String?) {}

    // MARK: - Errors

    static func trackResponseError(error: String) {}

    static func trackTTSError(error: String) {}
}
