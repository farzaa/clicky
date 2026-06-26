//
//  GroundingTelemetryRecorderTests.swift
//  leanring-buddyTests
//
//  Tests for privacy-safe grounding telemetry metadata.
//

import Foundation
import Testing
@testable import Spider

@MainActor
struct GroundingTelemetryRecorderTests {
    @Test func guideResponseMetadataUsesOnlyPrivacySafeFields() async throws {
        let response = guideResponse(
            semanticSignature: "semantic:objective",
            point: guidePoint(
                targetElementId: "sales_tile",
                label: "Sales",
                missionAlignment: "Matches private plan",
                expectedOutcome: .tileSelected
            ),
            targets: [
                semanticTarget(elementId: "sales_tile", label: "Sales", state: "enabled"),
            ],
            screenState: .loading,
            stageId: "objective",
            screenConfidence: nil
        )

        let metadata = GroundingTelemetryRecorder.guideResponseMetadata(
            platform: .metaAds,
            guideResponse: response,
            resolvedScreenState: .recognized
        )

        #expect(metadata.platform == .metaAds)
        #expect(metadata.stageId == "objective")
        #expect(metadata.screenState == .recognized)
        #expect(metadata.screenConfidence == .high)
        #expect(metadata.semanticSignature == "semantic:objective")
    }

    @Test func hashesRejectedPointIdentity() async throws {
        let response = guideResponse(
            semanticSignature: "semantic:objective",
            point: guidePoint(targetElementId: "sales_tile", expectedOutcome: .tileSelected),
            targets: [
                semanticTarget(elementId: "sales_tile", label: "Sales", state: "enabled"),
            ]
        )
        let metadata = try #require(GroundingTelemetryRecorder.pointRejectionMetadata(
            for: response,
            resolvedScreenState: .recognized,
            retryPolicy: nil
        ))

        #expect(metadata.targetElementIdHash == SpiderGroundingPrivacy.targetElementIdHash(for: "sales_tile"))
        #expect(metadata.targetElementIdHash != "sales_tile")
        #expect(metadata.expectedOutcome == .tileSelected)
        #expect(GroundingTelemetryRecorder.shouldTrackShadowCandidate(for: response))
        #expect(!GroundingTelemetryRecorder.shouldTrackShadowCandidate(for: guideResponse(
            semanticSignature: "semantic:no-point",
            point: nil,
            targets: []
        )))
    }

    @Test func hashesAcceptedPointIdentity() async throws {
        let metadata = GroundingTelemetryRecorder.pointAcceptanceMetadata(
            for: guidePoint(targetElementId: "sales_tile", expectedOutcome: .tileSelected),
            sensorFusionDecision: nil
        )

        #expect(metadata.targetElementIdHash == SpiderGroundingPrivacy.targetElementIdHash(for: "sales_tile"))
        #expect(metadata.targetElementIdHash != "sales_tile")
        #expect(metadata.expectedOutcome == .tileSelected)
        #expect(metadata.targetFingerprint == nil)
    }
}
