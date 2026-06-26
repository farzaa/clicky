//
//  CompanionGuidePointTelemetryRecorderTests.swift
//  leanring-buddyTests
//
//  Tests for the Companion-level guide point telemetry boundary.
//

import Foundation
import Testing
@testable import Spider

@MainActor
struct CompanionGuidePointTelemetryRecorderTests {
    @Test func acceptedPointTelemetryReturnsMetadataAndTimeToDot() async throws {
        let point = guidePoint(targetElementId: "sales_tile", expectedOutcome: .tileSelected)
        let response = guideResponse(
            semanticSignature: "semantic:objective",
            point: point,
            targets: [
                semanticTarget(elementId: "sales_tile", label: "Sales", state: "enabled"),
            ]
        )
        let metadata = GroundingTelemetryRecorder.guideResponseMetadata(
            platform: .metaAds,
            guideResponse: response,
            resolvedScreenState: .recognized
        )

        let acceptedTelemetry = CompanionGuidePointTelemetryRecorder.recordAccepted(
            guidePoint: point,
            metadata: metadata,
            sensorFusionDecision: nil,
            groundingTelemetryStartedAt: Date(timeIntervalSince1970: 100),
            screenshotCaptureLatencyMs: 10,
            visionRequestLatencyMs: 20,
            screenChanged: false,
            pollIndex: 1,
            now: Date(timeIntervalSince1970: 100.12)
        )

        #expect(acceptedTelemetry.timeToDotMs == 120)
        #expect(acceptedTelemetry.pointMetadata.targetElementIdHash == SpiderGroundingPrivacy.targetElementIdHash(for: "sales_tile"))
        #expect(acceptedTelemetry.pointMetadata.expectedOutcome == .tileSelected)
        #expect(acceptedTelemetry.pointMetadata.targetFingerprint == nil)
    }
}
