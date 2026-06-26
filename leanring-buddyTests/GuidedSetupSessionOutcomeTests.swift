//
//  GuidedSetupSessionOutcomeTests.swift
//  leanring-buddyTests
//
//  Domain tests for guided setup pre-dot verification, negative memory, and point outcome confirmation.
//

import Foundation
import Testing
@testable import Spider

@MainActor
struct GuidedSetupSessionOutcomeTests {
    @Test func preDotVerificationRequiresSecondCompatibleFrame() async throws {
        var session = GuidedSetupSession(platformId: .metaAds)
        let point = guidePoint(expectedOutcome: .tileSelected)
        let firstResponse = guideResponse(
            semanticSignature: "semantic:objective",
            point: point,
            targets: [
                semanticTarget(elementId: "sales_tile", label: "Sales", state: "enabled", targetStability: "new"),
            ]
        )
        let firstDecision = GroundingSensorFusion.decisionForTesting(
            signals: [
                .confirmed(.cursorMetadata),
                .weaklyConfirmed(.browserMetadata),
            ],
            preDotVerificationReasons: [.targetNewOrUnknown, .regionUnstable]
        )

        let firstPreDot = session.resolvePreDotVerification(
            response: firstResponse,
            sensorFusionDecision: firstDecision,
            screenSignature: "screen:one",
            screenChanged: false,
            pollIndex: 1
        )

        #expect(firstPreDot.status == .pending)
        #expect(firstPreDot.reason == .preDotVerificationPending)
        #expect(session.pendingPreDotVerification != nil)

        let secondResponse = guideResponse(
            semanticSignature: "semantic:objective",
            point: point,
            targets: [
                semanticTarget(elementId: "sales_tile_v2", label: "Purchases", state: "enabled", targetStability: "stable"),
            ]
        )
        let secondDecision = GroundingSensorFusion.decisionForTesting(
            signals: [
                .confirmed(.cursorMetadata),
                .weaklyConfirmed(.browserMetadata),
            ]
        )
        let secondPreDot = session.resolvePreDotVerification(
            response: secondResponse,
            sensorFusionDecision: secondDecision,
            screenSignature: "screen:two",
            screenChanged: false,
            pollIndex: 2
        )

        #expect(secondPreDot.status == .confirmed)
        #expect(secondPreDot.reason == nil)
        #expect(session.pendingPreDotVerification == nil)
    }

    @Test func preDotVerificationTimeoutFailsClosed() async throws {
        var session = GuidedSetupSession(platformId: .metaAds)
        let point = guidePoint(expectedOutcome: .tileSelected)
        let response = guideResponse(
            semanticSignature: "semantic:objective",
            point: point,
            targets: [
                semanticTarget(elementId: "sales_tile", label: "Sales", state: "enabled", targetStability: "new"),
            ]
        )
        let decision = GroundingSensorFusion.decisionForTesting(
            signals: [
                .confirmed(.cursorMetadata),
                .weaklyConfirmed(.browserMetadata),
            ],
            preDotVerificationReasons: [.targetNewOrUnknown]
        )
        let startedAt = Date(timeIntervalSince1970: 100)
        let firstPreDot = session.resolvePreDotVerification(
            response: response,
            sensorFusionDecision: decision,
            screenSignature: "screen:one",
            screenChanged: false,
            pollIndex: 1,
            policy: fusionPolicy(preDotVerificationMaxMs: 50),
            now: startedAt
        )

        let timedOutPreDot = session.resolvePreDotVerification(
            response: response,
            sensorFusionDecision: decision,
            screenSignature: "screen:one",
            screenChanged: false,
            pollIndex: 2,
            policy: fusionPolicy(preDotVerificationMaxMs: 50),
            now: startedAt.addingTimeInterval(0.12)
        )

        #expect(firstPreDot.status == .pending)
        #expect(timedOutPreDot.status == .failed)
        #expect(timedOutPreDot.reason == .preDotVerificationTimeout)
        #expect((timedOutPreDot.latencyMs ?? 0) >= 120)
        #expect(session.pendingPreDotVerification == nil)
    }

    @Test func negativeMemoryBlocksRepeatedFailedFingerprintUntilSignatureChanges() async throws {
        var session = GuidedSetupSession(platformId: .metaAds)
        let point = guidePoint(targetElementId: nil, expectedOutcome: .tileSelected)
        let blockedResponse = guideResponse(
            semanticSignature: "semantic:objective",
            point: point,
            targets: [
                semanticTarget(elementId: "sales_tile", label: "Sales", state: "enabled"),
            ]
        )
        let decision = await GroundingSensorFusion.evaluate(
            guideResponse: blockedResponse,
            guidePoint: point,
            screenCaptures: [syntheticScreenCapture()],
            screenChanged: false
        )

        session.rememberNegativeTarget(
            response: blockedResponse,
            sensorFusionDecision: decision,
            screenSignature: "screen:objective",
            reason: .sensorContradiction,
            pollIndex: 1
        )

        let repeatResponse = guideResponse(
            semanticSignature: "semantic:objective",
            point: point,
            targets: [
                semanticTarget(elementId: "sales_tile_v2", label: "Purchases", state: "enabled"),
            ]
        )
        let changedSignatureResponse = guideResponse(
            semanticSignature: "semantic:changed",
            point: point,
            targets: [
                semanticTarget(elementId: "sales_tile_v2", label: "Purchases", state: "enabled"),
            ]
        )

        #expect(session.shouldRejectNegativeMemory(repeatResponse))
        #expect(!session.shouldRejectNegativeMemory(changedSignatureResponse))
    }

    @Test func outcomeModalOpenedConfirmsFromSemanticContainer() async throws {
        var session = GuidedSetupSession(platformId: .metaAds)
        let point = guidePoint(expectedOutcome: .modalOpened)
        let startingResponse = guideResponse(
            semanticSignature: "semantic:before",
            point: point,
            targets: [
                semanticTarget(elementId: "create", label: "Create", state: "enabled"),
            ]
        )
        session.record(
            response: startingResponse,
            screenSignature: "screen:before",
            resolvedScreenState: .recognized,
            screenChanged: true,
            acceptedPoint: point,
            acceptedPointTargetElementIdHash: nil,
            acceptedPointTargetFingerprint: nil
        )

        let nextResponse = guideResponse(
            semanticSignature: "semantic:before",
            point: nil,
            targets: [
                semanticTarget(elementId: "modal_continue", label: "Continue", container: "modal", state: "enabled"),
            ]
        )
        let decision = session.evaluatePendingPointOutcome(
            response: nextResponse,
            resolvedScreenState: .recognized,
            screenChanged: false
        )

        #expect(decision?.outcomeStatus == .confirmed)
        #expect(decision?.actualOutcomeEvidence.modalVisible == true)
    }

    @Test func outcomeItemSelectedConfirmsFromSelectedState() async throws {
        var session = GuidedSetupSession(platformId: .metaAds)
        let point = guidePoint(targetElementId: "sales_tile", expectedOutcome: .itemSelected)
        let targetElementIdHash = SpiderGroundingPrivacy.targetElementIdHash(for: "sales_tile")
        let startingResponse = guideResponse(
            semanticSignature: "semantic:before",
            point: point,
            targets: [
                semanticTarget(elementId: "sales_tile", label: "Sales", state: "enabled"),
            ]
        )
        session.record(
            response: startingResponse,
            screenSignature: "screen:before",
            resolvedScreenState: .recognized,
            screenChanged: true,
            acceptedPoint: point,
            acceptedPointTargetElementIdHash: targetElementIdHash,
            acceptedPointTargetFingerprint: nil
        )

        let nextResponse = guideResponse(
            semanticSignature: "semantic:before",
            point: nil,
            targets: [
                semanticTarget(elementId: "sales_tile", label: "Sales", state: "selected"),
            ]
        )
        let decision = session.evaluatePendingPointOutcome(
            response: nextResponse,
            resolvedScreenState: .recognized,
            screenChanged: false
        )

        #expect(decision?.outcomeStatus == .confirmed)
        #expect(decision?.actualOutcomeEvidence.selectedTargetVisible == true)
    }

    @Test func outcomeDropdownOpenedConfirmsFromVisiblePopover() async throws {
        var session = GuidedSetupSession(platformId: .metaAds)
        let point = guidePoint(expectedOutcome: .dropdownOpened)
        session.record(
            response: guideResponse(
                semanticSignature: "semantic:before",
                point: point,
                targets: [
                    semanticTarget(elementId: "dropdown", label: "Select", role: "button", state: "enabled"),
                ]
            ),
            screenSignature: "screen:before",
            resolvedScreenState: .recognized,
            screenChanged: true,
            acceptedPoint: point,
            acceptedPointTargetElementIdHash: nil,
            acceptedPointTargetFingerprint: nil
        )

        let decision = session.evaluatePendingPointOutcome(
            response: guideResponse(
                semanticSignature: "semantic:after",
                point: nil,
                targets: [
                    semanticTarget(elementId: "dropdown_menu", label: "Option", role: "menu", container: "popover", state: "open"),
                ]
            ),
            resolvedScreenState: .recognized,
            screenChanged: true
        )

        #expect(decision?.outcomeStatus == .confirmed)
        #expect(decision?.actualOutcomeEvidence.dropdownVisible == true)
    }

    @Test func failedOutcomeRejectsCompatibleFingerprintUntilSignatureChanges() async throws {
        var session = GuidedSetupSession(platformId: .metaAds)
        let point = guidePoint(targetElementId: nil, expectedOutcome: .tileSelected)
        let startingTarget = semanticTarget(elementId: "sales_tile", label: "Sales", state: "enabled")
        let startingResponse = guideResponse(
            semanticSignature: "semantic:before",
            point: point,
            targets: [startingTarget]
        )
        let fingerprint = try #require(TargetFingerprint.make(
            target: startingTarget,
            grounding: startingResponse.semanticGrounding,
            stageId: startingResponse.stageId,
            expectedOutcome: point.expectedOutcome
        ))
        session.record(
            response: startingResponse,
            screenSignature: "screen:before",
            resolvedScreenState: .recognized,
            screenChanged: true,
            acceptedPoint: point,
            acceptedPointTargetElementIdHash: nil,
            acceptedPointTargetFingerprint: fingerprint
        )

        _ = session.evaluatePendingPointOutcome(
            response: guideResponse(
                semanticSignature: "semantic:before",
                point: nil,
                targets: [startingTarget]
            ),
            resolvedScreenState: .recognized,
            screenChanged: false
        )

        let repeatPoint = guidePoint(targetElementId: nil, expectedOutcome: .tileSelected)
        let repeatResponse = guideResponse(
            semanticSignature: "semantic:before",
            point: repeatPoint,
            targets: [
                semanticTarget(elementId: "sales_tile_v2", label: "Purchases", state: "enabled"),
            ]
        )

        #expect(session.shouldRejectRepeatedFailedPoint(repeatResponse))
    }
}
