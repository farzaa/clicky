//
//  SpiderGroundingTelemetryPayloadBuilder.swift
//  leanring-buddy
//
//  Converts typed grounding telemetry events into the final allowlisted string
//  payload. This is the only layer that should assemble emitted telemetry keys.
//

import Foundation

enum SpiderGroundingTelemetryPayloadBuilder {
    static func sanitizedPayload(for event: SpiderGroundingTelemetryEvent) -> [String: String] {
        var payload: [String: String] = [
            "platform": event.platform.rawValue,
            "timestamp": SpiderGroundingTelemetrySanitizer.timestampString(event.timestamp),
            "groundingSchemaVersion": String(event.groundingSchemaVersion),
        ]

        assignIdentifiers(from: event, to: &payload)
        assignScreenMetadata(from: event, to: &payload)
        assignDecisionMetadata(from: event, to: &payload)
        assignLatencyMetadata(from: event, to: &payload)
        assignRetryPolicy(from: event, to: &payload)
        assignSensorFusionMetadata(from: event, to: &payload)
        assignDotMetadata(from: event, to: &payload)

        return payload.filter { SpiderGroundingTelemetrySanitizer.allowedPayloadKeys.contains($0.key) }
    }

    private static func assignIdentifiers(
        from event: SpiderGroundingTelemetryEvent,
        to payload: inout [String: String]
    ) {
        SpiderGroundingTelemetrySanitizer.assign(
            &payload,
            key: "stageId",
            value: event.stageId,
            maxCharacters: SpiderGroundingTelemetrySanitizer.maxIdentifierCharacters
        )
        SpiderGroundingTelemetrySanitizer.assign(
            &payload,
            key: "semanticSignature",
            value: event.semanticSignature,
            maxCharacters: SpiderContentLimits.maxScreenSignatureCharacters
        )
        SpiderGroundingTelemetrySanitizer.assign(
            &payload,
            key: "targetElementIdHash",
            value: event.targetElementIdHash,
            maxCharacters: SpiderGroundingTelemetrySanitizer.sha256HexCharacterCount
        )
        SpiderGroundingTelemetrySanitizer.assign(
            &payload,
            key: "appVersion",
            value: event.appVersion,
            maxCharacters: SpiderGroundingTelemetrySanitizer.maxAppVersionCharacters
        )
    }

    private static func assignScreenMetadata(
        from event: SpiderGroundingTelemetryEvent,
        to payload: inout [String: String]
    ) {
        if let screenState = event.screenState {
            payload["screenState"] = screenState.rawValue
        }
        if let screenConfidence = event.screenConfidence {
            payload["screenConfidence"] = screenConfidence.rawValue
        }
        if let screenChanged = event.screenChanged {
            payload["screenChanged"] = String(screenChanged)
        }
        if let pollIndex = event.pollIndex {
            payload["pollIndex"] = String(max(0, pollIndex))
        }
    }

    private static func assignDecisionMetadata(
        from event: SpiderGroundingTelemetryEvent,
        to payload: inout [String: String]
    ) {
        if let expectedOutcome = event.expectedOutcome {
            payload["expectedOutcome"] = expectedOutcome.rawValue
            payload["outcomeKind"] = GroundingExpectedOutcomeKind(expectedOutcome: expectedOutcome).rawValue
        }
        if let rejectionReason = event.rejectionReason {
            payload["rejectionReason"] = rejectionReason.rawValue
        }
        if let outcomeStatus = event.outcomeStatus {
            payload["outcomeStatus"] = outcomeStatus.rawValue
        }
    }

    private static func assignLatencyMetadata(
        from event: SpiderGroundingTelemetryEvent,
        to payload: inout [String: String]
    ) {
        if let latencyMs = event.latencyMs {
            payload["latencyMs"] = SpiderGroundingTelemetrySanitizer.latencyString(latencyMs)
            payload["totalPointDecisionLatencyMs"] = payload["latencyMs"]
        }
        SpiderGroundingTelemetrySanitizer.assignLatency(
            &payload,
            key: "screenshotCaptureLatencyMs",
            value: event.screenshotCaptureLatencyMs
        )
        SpiderGroundingTelemetrySanitizer.assignLatency(
            &payload,
            key: "visionRequestLatencyMs",
            value: event.visionRequestLatencyMs
        )
        SpiderGroundingTelemetrySanitizer.assignLatency(
            &payload,
            key: "workerValidationLatencyMs",
            value: event.workerValidationLatencyMs
        )
        SpiderGroundingTelemetrySanitizer.assignLatency(
            &payload,
            key: "preDotVerificationLatencyMs",
            value: event.preDotVerificationLatencyMs
        )
        SpiderGroundingTelemetrySanitizer.assignLatency(
            &payload,
            key: "timeToDotMs",
            value: event.timeToDotMs
        )
    }

    private static func assignRetryPolicy(
        from event: SpiderGroundingTelemetryEvent,
        to payload: inout [String: String]
    ) {
        guard let retryPolicy = event.retryPolicy else { return }

        payload["retryAllowed"] = String(retryPolicy.allowRetry)
        payload["maxAttemptsForSameTarget"] = String(retryPolicy.maxAttemptsForSameTarget)
        payload["requiresNewSemanticSignature"] = String(retryPolicy.requiresNewSemanticSignature)
        payload["requiresTargetReappearance"] = String(retryPolicy.requiresTargetReappearance)
        payload["retryReason"] = retryPolicy.reason.rawValue
        payload["requiresUserConfirmationAfterFailure"] = String(retryPolicy.requiresUserConfirmationAfterFailure)
        payload["doNotRepeatUntilSignatureChanges"] = String(retryPolicy.doNotRepeatUntilSignatureChanges)
    }

    private static func assignSensorFusionMetadata(
        from event: SpiderGroundingTelemetryEvent,
        to payload: inout [String: String]
    ) {
        guard let sensorFusionDecision = event.sensorFusionDecision else { return }

        payload["fusionDecision"] = sensorFusionDecision.finalDecision.rawValue
        payload["fusionShouldBlockPoint"] = String(sensorFusionDecision.shouldBlockPoint)
        payload["actionRisk"] = sensorFusionDecision.evidence.actionRisk.rawValue
        payload["screenType"] = sensorFusionDecision.evidence.screenType.rawValue
        payload["stageType"] = sensorFusionDecision.evidence.stageType.rawValue
        payload["journeyTransition"] = sensorFusionDecision.evidence.journeyDecision.transition.rawValue
        payload["journeyAllowsDot"] = String(sensorFusionDecision.evidence.journeyDecision.allowsDot)
        payload["calibrationDecision"] = sensorFusionDecision.evidence.calibrationDecision.rawValue
        payload["fastPathDecision"] = sensorFusionDecision.evidence.fastPathDecision.rawValue
        payload["dotSuppressedByLatency"] = String(
            event.dotSuppressedByLatency ?? sensorFusionDecision.evidence.dotSuppressedByLatency
        )
        payload["requiresPreDotVerification"] = String(sensorFusionDecision.requiresPreDotVerification)
        payload["preDotVerificationReason"] = sensorFusionDecision.evidence.preDotVerificationReasons
            .map(\.rawValue)
            .joined(separator: ",")

        if let targetFingerprint = sensorFusionDecision.evidence.targetFingerprint {
            payload["targetFingerprint"] = targetFingerprint.value
            payload["targetFingerprintCompatibility"] = targetFingerprint.compatibilityValue
        }

        payload["regionConfidence"] = sensorFusionDecision.evidence.regionQuality.regionConfidence.rawValue
        payload["regionSource"] = sensorFusionDecision.evidence.regionQuality.regionSource.rawValue
        payload["regionStability"] = sensorFusionDecision.evidence.regionQuality.regionStability.rawValue
        payload["regionPlausibility"] = sensorFusionDecision.evidence.regionQuality.regionPlausibility.rawValue
        payload["pointInsideRegionConfidence"] = sensorFusionDecision.evidence.regionQuality.pointInsideRegionConfidence.rawValue
        payload["sensorFusionLatencyMs"] = SpiderGroundingTelemetrySanitizer.latencyString(
            sensorFusionDecision.evidence.latency.sensorFusionLatencyMs
        )
        SpiderGroundingTelemetrySanitizer.assignLatency(
            &payload,
            key: "ocrLatencyMs",
            value: sensorFusionDecision.evidence.latency.ocrLatencyMs
        )
        SpiderGroundingTelemetrySanitizer.assignLatency(
            &payload,
            key: "axLatencyMs",
            value: sensorFusionDecision.evidence.latency.axLatencyMs
        )
        SpiderGroundingTelemetrySanitizer.assignLatency(
            &payload,
            key: "browserMetadataLatencyMs",
            value: sensorFusionDecision.evidence.latency.browserMetadataLatencyMs
        )
        payload["confirmedSources"] = sensorFusionDecision.confirmedSources
            .map(\.rawValue)
            .joined(separator: ",")
        payload["contradictedSources"] = sensorFusionDecision.contradictedSources
            .map(\.rawValue)
            .joined(separator: ",")
        payload["contradictionReason"] = sensorFusionDecision.contradictionReasons
            .map(\.rawValue)
            .joined(separator: ",")
    }

    private static func assignDotMetadata(
        from event: SpiderGroundingTelemetryEvent,
        to payload: inout [String: String]
    ) {
        if let wouldHaveShownDot = event.wouldHaveShownDot {
            payload["wouldHaveShownDot"] = String(wouldHaveShownDot)
        }
        if event.sensorFusionDecision == nil,
           let dotSuppressedByLatency = event.dotSuppressedByLatency {
            payload["dotSuppressedByLatency"] = String(dotSuppressedByLatency)
        }
    }
}
