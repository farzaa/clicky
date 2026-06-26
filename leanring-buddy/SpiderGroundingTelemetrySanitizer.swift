//
//  SpiderGroundingTelemetrySanitizer.swift
//  leanring-buddy
//
//  Allowlisted, metadata-only payload sanitization for grounding telemetry.
//

import Foundation

enum SpiderGroundingTelemetrySanitizer {
    static let groundingSchemaVersion = 6
    static let maxIdentifierCharacters = 128
    static let maxAppVersionCharacters = 48
    static let maxLatencyMs = 300_000
    static let sha256HexCharacterCount = 64
    static let allowedPayloadKeys: Set<String> = [
        "platform",
        "stageId",
        "screenState",
        "screenConfidence",
        "semanticSignature",
        "targetElementIdHash",
        "targetFingerprint",
        "targetFingerprintCompatibility",
        "actionRisk",
        "screenType",
        "stageType",
        "journeyTransition",
        "journeyAllowsDot",
        "calibrationDecision",
        "fastPathDecision",
        "dotSuppressedByLatency",
        "requiresPreDotVerification",
        "preDotVerificationReason",
        "wouldHaveShownDot",
        "expectedOutcome",
        "outcomeKind",
        "rejectionReason",
        "outcomeStatus",
        "regionConfidence",
        "regionSource",
        "regionStability",
        "regionPlausibility",
        "pointInsideRegionConfidence",
        "latencyMs",
        "screenshotCaptureLatencyMs",
        "visionRequestLatencyMs",
        "workerValidationLatencyMs",
        "preDotVerificationLatencyMs",
        "timeToDotMs",
        "sensorFusionLatencyMs",
        "ocrLatencyMs",
        "axLatencyMs",
        "browserMetadataLatencyMs",
        "totalPointDecisionLatencyMs",
        "screenChanged",
        "pollIndex",
        "retryAllowed",
        "maxAttemptsForSameTarget",
        "requiresNewSemanticSignature",
        "requiresTargetReappearance",
        "retryReason",
        "requiresUserConfirmationAfterFailure",
        "doNotRepeatUntilSignatureChanges",
        "fusionDecision",
        "fusionShouldBlockPoint",
        "confirmedSources",
        "contradictedSources",
        "contradictionReason",
        "timestamp",
        "appVersion",
        "groundingSchemaVersion",
    ]

    private static let safeIdentifierPattern = #"^[A-Za-z0-9._:+-]+$"#

    static func assign(
        _ payload: inout [String: String],
        key: String,
        value: String?,
        maxCharacters: Int
    ) {
        guard let sanitizedValue = sanitizedIdentifier(value, maxCharacters: maxCharacters) else {
            return
        }
        payload[key] = sanitizedValue
    }

    static func sanitizedIdentifier(_ value: String?, maxCharacters: Int) -> String? {
        let sanitizedValue = value?.spiderSanitizedSingleLine(maxCharacters: maxCharacters) ?? ""
        guard !sanitizedValue.isEmpty,
              sanitizedValue.range(of: safeIdentifierPattern, options: .regularExpression) != nil else {
            return nil
        }
        return sanitizedValue
    }

    static func timestampString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func assignLatency(
        _ payload: inout [String: String],
        key: String,
        value: Int?
    ) {
        guard let value else { return }
        payload[key] = latencyString(value)
    }

    static func latencyString(_ value: Int) -> String {
        String(max(0, min(value, maxLatencyMs)))
    }
}
