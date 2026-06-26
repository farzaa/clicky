//
//  CompanionPreDotVerificationCoordinatorTests.swift
//  leanring-buddyTests
//
//  Tests for the pre-dot verification boundary used by CompanionManager.
//

import Foundation
import Testing
@testable import Spider

@MainActor
struct CompanionPreDotVerificationCoordinatorTests {
    @Test func requiresPreDotWithoutSessionReturnsPendingRejection() async throws {
        let decision = GroundingSensorFusion.decisionForTesting(
            signals: [
                .confirmed(.cursorMetadata),
                .weaklyConfirmed(.browserMetadata),
            ],
            preDotVerificationReasons: [.targetNewOrUnknown]
        )
        let response = guideResponse(
            semanticSignature: "semantic:objective",
            point: guidePoint(expectedOutcome: .tileSelected),
            targets: [
                semanticTarget(elementId: "sales_tile", label: "Sales", state: "enabled", targetStability: "new"),
            ]
        )

        let resolution = CompanionPreDotVerificationCoordinator.resolve(
            guideResponse: response,
            sensorFusionDecision: decision,
            pointWasEvaluated: true,
            guidedSetupSession: nil,
            screenSignature: "screen:objective",
            screenChanged: false,
            pollIndex: 1
        )

        #expect(resolution.guidedSetupSession == nil)
        #expect(resolution.rejectionReason == .preDotVerificationPending)
        #expect(resolution.latencyMs == nil)
        #expect(!resolution.didFailVerification)
    }

    @Test func blockingDecisionStoresNegativeMemoryWhenSessionExists() async throws {
        let decision = GroundingSensorFusion.decisionForTesting(
            signals: [
                .confirmed(.cursorMetadata),
            ],
            policyContradictions: [
                .actionRiskBlocked,
            ]
        )
        let response = guideResponse(
            semanticSignature: "semantic:objective",
            point: guidePoint(expectedOutcome: .tileSelected),
            targets: [
                semanticTarget(elementId: "sales_tile", label: "Sales", state: "enabled"),
            ]
        )
        let session = GuidedSetupSession(platformId: .metaAds)

        let resolution = CompanionPreDotVerificationCoordinator.resolve(
            guideResponse: response,
            sensorFusionDecision: decision,
            pointWasEvaluated: true,
            guidedSetupSession: session,
            screenSignature: "screen:objective",
            screenChanged: false,
            pollIndex: 1
        )

        #expect(resolution.guidedSetupSession?.negativeMemories.count == 1)
        #expect(resolution.guidedSetupSession?.negativeMemories.first?.reason == .actionRiskBlocked)
        #expect(resolution.rejectionReason == nil)
        #expect(resolution.latencyMs == nil)
        #expect(!resolution.didFailVerification)
    }

    @Test func pendingVerificationTimeoutReportsFailureAndLatency() async throws {
        let decision = GroundingSensorFusion.decisionForTesting(
            signals: [
                .confirmed(.cursorMetadata),
                .weaklyConfirmed(.browserMetadata),
            ],
            preDotVerificationReasons: [.targetNewOrUnknown]
        )
        let response = guideResponse(
            semanticSignature: "semantic:objective",
            point: guidePoint(expectedOutcome: .tileSelected),
            targets: [
                semanticTarget(elementId: "sales_tile", label: "Sales", state: "enabled", targetStability: "new"),
            ]
        )
        let startedAt = Date(timeIntervalSince1970: 100)
        let policy = fusionPolicy(preDotVerificationMaxMs: 50)

        let pendingResolution = CompanionPreDotVerificationCoordinator.resolve(
            guideResponse: response,
            sensorFusionDecision: decision,
            pointWasEvaluated: true,
            guidedSetupSession: GuidedSetupSession(platformId: .metaAds),
            screenSignature: "screen:objective",
            screenChanged: false,
            pollIndex: 1,
            policy: policy,
            now: startedAt
        )

        let failedResolution = CompanionPreDotVerificationCoordinator.resolve(
            guideResponse: response,
            sensorFusionDecision: decision,
            pointWasEvaluated: true,
            guidedSetupSession: pendingResolution.guidedSetupSession,
            screenSignature: "screen:objective",
            screenChanged: false,
            pollIndex: 2,
            policy: policy,
            now: startedAt.addingTimeInterval(0.12)
        )

        #expect(pendingResolution.rejectionReason == .preDotVerificationPending)
        #expect(pendingResolution.guidedSetupSession?.pendingPreDotVerification != nil)
        #expect(failedResolution.guidedSetupSession?.pendingPreDotVerification == nil)
        #expect(failedResolution.rejectionReason == .preDotVerificationTimeout)
        #expect((failedResolution.latencyMs ?? 0) >= 120)
        #expect(failedResolution.didFailVerification)
        #expect(failedResolution.guidedSetupSession?.negativeMemories.count == 1)
    }

    @Test func missingEvaluatedPointLeavesSessionUnchanged() async throws {
        let decision = GroundingSensorFusion.decisionForTesting(
            signals: [
                .confirmed(.cursorMetadata),
                .weaklyConfirmed(.browserMetadata),
            ],
            preDotVerificationReasons: [.targetNewOrUnknown]
        )
        let session = GuidedSetupSession(platformId: .metaAds)
        let response = guideResponse(
            semanticSignature: "semantic:objective",
            point: nil,
            targets: []
        )

        let resolution = CompanionPreDotVerificationCoordinator.resolve(
            guideResponse: response,
            sensorFusionDecision: decision,
            pointWasEvaluated: false,
            guidedSetupSession: session,
            screenSignature: "screen:objective",
            screenChanged: false,
            pollIndex: 1
        )

        #expect(resolution.guidedSetupSession?.pendingPreDotVerification == nil)
        #expect(resolution.guidedSetupSession?.negativeMemories.isEmpty == true)
        #expect(resolution.rejectionReason == nil)
        #expect(resolution.latencyMs == nil)
        #expect(!resolution.didFailVerification)
    }
}
