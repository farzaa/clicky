//
//  Analytics.swift
//  yardtalk
//
//  Analytics stubs — PostHog removed during YardTalk rebrand.
//  Wire up new analytics here if needed for v1.
//

import Foundation

enum Analytics {

    static func configure() {}

    static func trackAppOpened() {}

    static func trackOnboardingStarted() {}

    static func trackOnboardingReplayed() {}

    static func trackOnboardingVideoCompleted() {}

    static func trackOnboardingDemoTriggered() {}

    static func trackAllPermissionsGranted() {}

    static func trackPermissionGranted(permission: String) {}

    static func trackPushToTalkStarted() {}

    static func trackPushToTalkReleased() {}

    static func trackUserMessageSent(transcript: String) {}

    static func trackAIResponseReceived(response: String) {}

    static func trackElementPointed(elementLabel: String?) {}

    static func trackResponseError(error: String) {}

    static func trackTTSError(error: String) {}
}
