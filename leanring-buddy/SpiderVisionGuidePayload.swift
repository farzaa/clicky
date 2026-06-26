//
//  SpiderVisionGuidePayload.swift
//  leanring-buddy
//
//  Encodable request payloads sent from the macOS app to the authenticated
//  Spider Worker. The Worker, not the app, owns OpenAI credentials.
//

import Foundation

struct SpiderScreenCapturePayload: Encodable {
    let label: String
    let imageBase64: String
    let mimeType: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

struct SpiderGuidedSessionContext: Encodable {
    struct PreviousAcceptedTarget: Encodable {
        let label: String?
        let missionAlignment: String?
        let screenId: String?
        let stageId: String?
    }

    struct PendingPointOutcome: Encodable {
        let targetElementIdHash: String?
        let targetFingerprint: String?
        let targetFingerprintCompatibility: String?
        let screenId: String?
        let stageId: String?
        let semanticSignature: String?
        let groundingRevision: String?
        let expectedOutcome: SpiderGuideExpectedOutcome
        let retryAllowed: Bool?
        let retryReason: String?
        let requiresUserConfirmationAfterFailure: Bool?
        let doNotRepeatUntilSignatureChanges: Bool?
    }

    let currentScreenSignature: String
    let previousScreenSignature: String?
    let previousSemanticSignature: String?
    let screenChanged: Bool
    let pendingPointOutcome: PendingPointOutcome?
    let previousAcceptedTarget: PreviousAcceptedTarget?
}

struct SpiderVisionGuideRequest: Encodable {
    struct ConversationTurn: Encodable {
        let userTranscript: String
        let assistantResponse: String
    }

    let userTranscript: String
    let appLanguage: String
    let screenshots: [SpiderScreenCapturePayload]
    let platformContext: SpiderPlatformContext?
    let guidedSessionContext: SpiderGuidedSessionContext?
    let conversationHistory: [ConversationTurn]
    let adMissionSnapshot: AdMissionGuideSnapshot?
}
