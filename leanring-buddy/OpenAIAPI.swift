//
//  OpenAIAPI.swift
//  leanring-buddy
//
//  Spider guide DTOs and structured response contracts. Sanitization lives in
//  SpiderGuideResponseSanitization; Worker transport lives in
//  OpenAIVisionGuideClient.
//

import Foundation

enum SpiderGuideResponseValidationError: Error {
    case missingRequiredGuidanceText
}

enum OpenAIVisionGuideClientError: Error {
    case missingScreenshot
    case missingUserTranscript
    case missingSessionToken
    case invalidWorkerResponse
    case oversizedGuideResponse
    case invalidGuideResponse
}

struct SpiderGuideResponse: Codable, Equatable {
    let spokenText: String
    let displayText: String
    let nextStep: String
    let semanticGrounding: SpiderGuideSemanticGrounding?
    let screenState: SpiderGuideScreenState?
    let screenId: String?
    let stageId: String?
    let screenConfidence: SpiderGuideConfidence?
    let screenEvidence: [String]?
    let shouldContinuePolling: Bool?
    let pollAfterMs: Int?
    let contextKind: SpiderGuideContextKind
    let officialRule: String?
    let spiderJudgment: String
    let decision: SpiderGuideDecision
    let riskLevel: SpiderGuideRiskLevel
    let confidence: SpiderGuideConfidence
    let sourceType: SpiderGuideSourceType
    let requiresManualConfirmation: Bool
    let reviewTrigger: String?
    let decisionMemoryUpdate: String?
    let point: SpiderGuidePoint?
    let adMissionUpdate: AdMissionUpdate?
    let artifact: SpiderArtifact?
}
