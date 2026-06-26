//
//  CompanionGuidePointEvaluatorTests.swift
//  leanring-buddyTests
//
//  Tests for the guide point evaluation boundary used by CompanionManager.
//

import Foundation
import Testing
@testable import Spider

@MainActor
struct CompanionGuidePointEvaluatorTests {
    @Test func rejectsUnsafeScreenStateBeforeSensorFusion() async throws {
        let response = guideResponse(
            semanticSignature: "semantic:loading",
            point: guidePoint(expectedOutcome: .tileSelected),
            targets: [
                semanticTarget(elementId: "sales_tile", label: "Sales", state: "enabled"),
            ],
            screenState: .loading
        )
        let metadata = GroundingTelemetryRecorder.guideResponseMetadata(
            platform: .metaAds,
            guideResponse: response,
            resolvedScreenState: .loading
        )

        let evaluation = await CompanionGuidePointEvaluator.evaluate(
            guideResponse: response,
            resolvedScreenState: .loading,
            screenCaptures: [syntheticScreenCapture()],
            screenChanged: true,
            telemetryMetadata: metadata,
            groundingTelemetryStartedAt: Date(timeIntervalSince1970: 0),
            screenshotCaptureLatencyMs: 1,
            visionRequestLatencyMs: 2,
            pollIndex: nil
        )

        #expect(evaluation.point == nil)
        #expect(evaluation.rejectionReason == .unrecognizedScreen)
        #expect(evaluation.sensorFusionDecision == nil)
        #expect(evaluation.sensorFusionLatencyMs == nil)
    }

    @Test func sensorFusionRejectionStyleKeepsOnboardingDemoGeneric() async throws {
        let actionRiskDecision = GroundingSensorFusion.decisionForTesting(
            signals: [
                .confirmed(.cursorMetadata),
            ],
            policyContradictions: [
                .actionRiskBlocked,
            ]
        )

        #expect(
            CompanionGuidePointSensorFusionRejectionStyle.policySpecific
                .rejectionReason(for: actionRiskDecision) == .actionRiskBlocked
        )
        #expect(
            CompanionGuidePointSensorFusionRejectionStyle.genericContradiction
                .rejectionReason(for: actionRiskDecision) == .sensorFusionContradicted
        )
    }
}
