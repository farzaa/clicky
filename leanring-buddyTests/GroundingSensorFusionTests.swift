//
//  GroundingSensorFusionTests.swift
//  leanring-buddyTests
//
//  Domain tests for Vision-first target fusion, latency gates, action risk, and metadata-only telemetry.
//

import CoreGraphics
import Foundation
import Testing
@testable import Spider

@MainActor
struct GroundingSensorFusionTests {
    @Test func contradictionBlocksTheDot() async throws {
        let decision = GroundingSensorFusion.decisionForTesting(
            signals: [
                .confirmed(.cursorMetadata),
                .contradicted(.macOSAccessibility, [.accessibilityElementDisabled]),
            ]
        )

        #expect(decision.finalDecision == .contradicted)
        #expect(decision.shouldBlockPoint)
        #expect(decision.contradictedSources == [.macOSAccessibility])
        #expect(decision.contradictionReasons == [.accessibilityElementDisabled])
    }

    @Test func unavailableSignalsDoNotBlockVisionAlone() async throws {
        let decision = GroundingSensorFusion.decisionForTesting(
            signals: [
                .unavailable(.localOCR),
                .unavailable(.macOSAccessibility),
                .unavailable(.browserMetadata),
            ]
        )

        #expect(decision.finalDecision == .unavailable)
        #expect(!decision.shouldBlockPoint)
    }

    @Test func confirmationDoesNotCreateAnUnsafeOverride() async throws {
        let decision = GroundingSensorFusion.decisionForTesting(
            signals: [
                .confirmed(.cursorMetadata),
                .weaklyConfirmed(.browserMetadata),
            ]
        )

        #expect(decision.finalDecision == .weaklyConfirmed)
        #expect(!decision.shouldBlockPoint)
        #expect(decision.confirmedSources == [.cursorMetadata, .browserMetadata])
    }

    @Test func localOCRWeakMismatchDoesNotBlockTheDot() async throws {
        let signal = GroundingSensorFusion.localOCRSignalForTesting(
            expectedLabel: "Sales",
            candidates: [
                GroundingOCRCandidate(text: "Traffic", confidence: 0.62),
            ]
        )
        let decision = GroundingSensorFusion.decisionForTesting(
            signals: [
                .confirmed(.cursorMetadata),
                signal,
            ]
        )

        #expect(signal.result == .inconclusive)
        #expect(!decision.shouldBlockPoint)
    }

    @Test func localOCRStrongMismatchAloneIsDowngradedWhenCursorAndRegionAgree() async throws {
        let signal = GroundingSensorFusion.localOCRSignalForTesting(
            expectedLabel: "Sales",
            candidates: [
                GroundingOCRCandidate(text: "Traffic", confidence: 0.94),
                GroundingOCRCandidate(text: "Awareness", confidence: 0.91),
            ]
        )
        let decision = GroundingSensorFusion.decisionForTesting(
            signals: [
                .confirmed(.cursorMetadata),
                signal,
            ]
        )

        #expect(signal.result == .contradicted)
        #expect(!decision.shouldBlockPoint)
        #expect(decision.evidence.calibrationDecision == .downgradedOCROnlyContradiction)
        #expect(decision.contradictionReasons == [.ocrTextMismatch])
    }

    @Test func latencyCutoffTurnsSlowContradictionUnavailable() async throws {
        let degradedSignal = GroundingSensorFusion.signalForTesting(
            .contradicted(.browserMetadata, [.browserElementCovered]),
            applyingLatencyCutoffMs: 100,
            measuredLatencyMs: 400
        )
        let decision = GroundingSensorFusion.decisionForTesting(
            signals: [
                .confirmed(.cursorMetadata),
                degradedSignal,
            ]
        )

        #expect(degradedSignal.result == .unavailable)
        #expect(degradedSignal.contradictionReasons.isEmpty)
        #expect(!decision.shouldBlockPoint)
    }

    @Test func delayedOCRBecomesUnavailableAndDoesNotBlockSafeVision() async throws {
        let degradedOCR = GroundingSensorFusion.signalForTesting(
            .contradicted(.localOCR, [.ocrTextMismatch]),
            applyingLatencyCutoffMs: 100,
            measuredLatencyMs: 420
        )
        let decision = GroundingSensorFusion.decisionForTesting(
            signals: [
                .confirmed(.cursorMetadata),
                degradedOCR,
                .unavailable(.macOSAccessibility),
                .unavailable(.browserMetadata),
            ]
        )

        #expect(degradedOCR.result == .unavailable)
        #expect(degradedOCR.contradictionReasons.isEmpty)
        #expect(!decision.shouldBlockPoint)
    }

    @Test func browserContradictionInsideDeadlineBlocksTheDot() async throws {
        let decision = GroundingSensorFusion.decisionForTesting(
            signals: [
                .confirmed(.cursorMetadata),
                .contradicted(.browserMetadata, [.browserElementCovered]),
            ]
        )

        #expect(decision.finalDecision == .contradicted)
        #expect(decision.shouldBlockPoint)
        #expect(decision.contradictionReasons.contains(.browserElementCovered))
    }

    @Test func fastPathAcceptsSafeStableTargetAndSkipsOCR() async throws {
        let decision = GroundingSensorFusion.decisionForTesting(
            signals: [
                .confirmed(.cursorMetadata),
                .unavailable(.localOCR, latencyMs: 0),
                .unavailable(.macOSAccessibility),
                .weaklyConfirmed(.browserMetadata),
            ],
            fastPathDecision: .accepted
        )

        let ocrSignal = decision.evidence.signals.first { $0.source == .localOCR }
        #expect(decision.evidence.fastPathDecision == .accepted)
        #expect(ocrSignal?.result == .unavailable)
        #expect(ocrSignal?.latencyMs == 0)
        #expect(!decision.shouldBlockPoint)
    }

    @Test func fastPathAcceptsStrongReappearedTargetAfterScreenChange() async throws {
        let point = guidePoint(expectedOutcome: .tileSelected)
        let response = guideResponse(
            semanticSignature: "semantic:objective:v2",
            point: point,
            targets: [
                semanticTarget(elementId: "sales_tile_v2", label: "Purchases", state: "enabled"),
            ]
        )
        let browserMetadata = GroundingBrowserMetadata(
            source: .browserBridge,
            isWebSurface: true,
            roleCategory: .button,
            elementClickable: true,
            elementInteractable: true,
            elementDisabled: false,
            elementHidden: false,
            elementCovered: false
        )

        let decision = await GroundingSensorFusion.evaluate(
            guideResponse: response,
            guidePoint: point,
            screenCaptures: [
                syntheticScreenCapture(displayFrame: CGRect(x: 100_000, y: 100_000, width: 200, height: 120)),
            ],
            browserMetadata: browserMetadata,
            screenChanged: true,
            policy: fusionPolicy(fastPathMaxDecisionMs: 10_000)
        )

        #expect(decision.evidence.fastPathDecision == .accepted)
        #expect(decision.evidence.targetFingerprint != nil)
        #expect(decision.confirmedSources.contains(.cursorMetadata))
        #expect(!decision.requiresPreDotVerification)
        #expect(!decision.shouldBlockPoint)
    }

    @Test func fastPathNeverAcceptsBoundaryAction() async throws {
        let point = guidePoint(expectedOutcome: .screenAdvanced)
        let response = guideResponse(
            semanticSignature: "semantic:review",
            point: point,
            targets: [
                semanticTarget(elementId: "publish_button", label: "Publish campaign", state: "enabled"),
            ],
            stageId: "review_publish"
        )

        let decision = await GroundingSensorFusion.evaluate(
            guideResponse: response,
            guidePoint: point,
            screenCaptures: [syntheticScreenCapture()],
            screenChanged: false,
            policy: fusionPolicy(fastPathMaxDecisionMs: 10_000)
        )

        #expect(decision.evidence.fastPathDecision != .accepted)
        #expect(decision.evidence.actionRisk == .publishBoundary)
        #expect(decision.shouldBlockPoint)
    }

    @Test func fastPathRequiresHighRegionQuality() async throws {
        let decision = GroundingSensorFusion.decisionForTesting(
            signals: [
                .confirmed(.cursorMetadata),
                .weaklyConfirmed(.browserMetadata),
            ],
            regionQuality: RegionQuality(
                regionConfidence: .medium,
                regionSource: .vision,
                regionStability: .stable,
                regionPlausibility: .plausible,
                pointInsideRegionConfidence: .high
            ),
            preDotVerificationReasons: [.regionMedium],
            fastPathDecision: .blocked
        )

        #expect(decision.evidence.fastPathDecision == .blocked)
        #expect(decision.evidence.calibrationDecision == .requirePreDotVerification)
        #expect(decision.requiresPreDotVerification)
        #expect(!decision.shouldBlockPoint)
    }

    @Test func latencySuppressionFailsClosedForUncertainDecision() async throws {
        let decision = GroundingSensorFusion.decisionForTesting(
            signals: [
                .weaklyConfirmed(.browserMetadata),
                .unavailable(.localOCR),
            ],
            regionQuality: RegionQuality(
                regionConfidence: .medium,
                regionSource: .vision,
                regionStability: .unknown,
                regionPlausibility: .plausible,
                pointInsideRegionConfidence: .high
            ),
            fastPathDecision: .notEligible,
            dotSuppressedByLatency: true,
            latency: GroundingSensorFusionLatency(
                sensorFusionLatencyMs: 1_200,
                cursorMetadataLatencyMs: nil,
                ocrLatencyMs: 420,
                axLatencyMs: nil,
                browserMetadataLatencyMs: 20,
                totalPointDecisionLatencyMs: 1_200
            )
        )

        #expect(decision.evidence.dotSuppressedByLatency)
        #expect(decision.evidence.calibrationDecision == .strongBlock)
        #expect(decision.contradictionReasons.contains(.latencyBudgetExceeded))
        #expect(decision.shouldBlockPoint)
    }

    @Test func telemetryPayloadIsMetadataOnly() async throws {
        let decision = GroundingSensorFusion.decisionForTesting(
            signals: [
                .confirmed(.cursorMetadata),
                .contradicted(.localOCR, [.ocrTextMismatch]),
            ],
            fastPathDecision: .accepted,
            latency: GroundingSensorFusionLatency(
                sensorFusionLatencyMs: 42,
                cursorMetadataLatencyMs: 2,
                ocrLatencyMs: 30,
                axLatencyMs: 3,
                browserMetadataLatencyMs: 5,
                totalPointDecisionLatencyMs: 42
            )
        )
        let event = SpiderGroundingTelemetryEvent(
            name: .sensorFusionEvaluated,
            platform: .metaAds,
            stageId: "objective_selection",
            screenState: .recognized,
            screenConfidence: .high,
            semanticSignature: "semantic:test",
            targetElementIdHash: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            expectedOutcome: .itemSelected,
            rejectionReason: nil,
            outcomeStatus: nil,
            latencyMs: 120,
            screenshotCaptureLatencyMs: 12,
            visionRequestLatencyMs: 70,
            workerValidationLatencyMs: 8,
            preDotVerificationLatencyMs: 24,
            timeToDotMs: 130,
            dotSuppressedByLatency: false,
            screenChanged: false,
            pollIndex: 1,
            retryPolicy: nil,
            sensorFusionDecision: decision,
            wouldHaveShownDot: nil,
            timestamp: Date(timeIntervalSince1970: 0),
            appVersion: "test",
            groundingSchemaVersion: SpiderGroundingTelemetrySanitizer.groundingSchemaVersion
        )

        let payload = event.sanitizedPayload
        #expect(payload["fusionDecision"] == "weakly_confirmed")
        #expect(payload["confirmedSources"] == "cursor_metadata")
        #expect(payload["contradictedSources"] == "local_ocr")
        #expect(payload["contradictionReason"] == "ocr_text_mismatch")
        #expect(payload["sensorFusionLatencyMs"] == "42")
        #expect(payload["ocrLatencyMs"] == "30")
        #expect(payload["axLatencyMs"] == "3")
        #expect(payload["browserMetadataLatencyMs"] == "5")
        #expect(payload["screenshotCaptureLatencyMs"] == "12")
        #expect(payload["visionRequestLatencyMs"] == "70")
        #expect(payload["workerValidationLatencyMs"] == "8")
        #expect(payload["preDotVerificationLatencyMs"] == "24")
        #expect(payload["timeToDotMs"] == "130")
        #expect(payload["fastPathDecision"] == "accepted")
        #expect(payload["dotSuppressedByLatency"] == "false")
        #expect(payload["targetFingerprint"] == "test-target-fingerprint")
        #expect(payload["targetFingerprintCompatibility"] == "test-target-fingerprint-compat")
        #expect(payload["actionRisk"] == "selection")
        #expect(payload["screenType"] == "card_tile_selection")
        #expect(payload["stageType"] == "safe_setup")
        #expect(payload["calibrationDecision"] == "downgraded_ocr_only_contradiction")
        #expect(payload["regionConfidence"] == "high")
        #expect(payload["regionPlausibility"] == "plausible")
        #expect(payload["pointInsideRegionConfidence"] == "high")

        for forbiddenKey in [
            "screenshot",
            "transcript",
            "prompt",
            "visibleText",
            "point.label",
            "missionAlignment",
            "nearestText",
            "evidence",
            "targetElementId",
            "ocrText",
            "axValue",
            "domText",
            "browserText",
        ] {
            #expect(payload[forbiddenKey] == nil)
        }
    }

    @Test func granularExpectedOutcomeMappingKeepsLegacyCompatibility() async throws {
        let legacyItemSelection = ExpectedOutcomeEvidence(
            acceptedPoint: guidePoint(expectedOutcome: .itemSelected),
            targetElementIdHash: nil,
            targetFingerprint: nil,
            startingScreenId: "objective_selection",
            startingStageId: "objective",
            startingSemanticSignature: "semantic:before",
            startingGroundingRevision: nil
        )
        let granularFieldFocus = ExpectedOutcomeEvidence(
            acceptedPoint: guidePoint(expectedOutcome: .fieldFocused),
            targetElementIdHash: nil,
            targetFingerprint: nil,
            startingScreenId: "campaign_settings",
            startingStageId: "settings",
            startingSemanticSignature: "semantic:before",
            startingGroundingRevision: nil
        )

        #expect(legacyItemSelection.verificationKind == .tileSelected)
        #expect(granularFieldFocus.verificationKind == .fieldFocused)
    }

    @Test func targetFingerprintSurvivesSmallLayoutAndCopyChanges() async throws {
        let original = semanticTarget(
            elementId: "target",
            label: "Sales",
            state: "enabled",
            region: SpiderGuideRegion(x: 0, y: 0, width: 112, height: 44)
        )
        let shiftedCopy = semanticTarget(
            elementId: "target",
            label: "Purchases",
            state: "enabled",
            region: SpiderGuideRegion(x: 20, y: 0, width: 112, height: 44)
        )
        let differentContainer = semanticTarget(
            elementId: "target",
            label: "Purchases",
            container: "modal",
            state: "enabled",
            region: SpiderGuideRegion(x: 20, y: 0, width: 112, height: 44)
        )

        let firstGrounding = semanticGrounding(semanticSignature: "semantic:objective", targets: [original])
        let shiftedGrounding = semanticGrounding(semanticSignature: "semantic:objective", targets: [shiftedCopy])
        let differentGrounding = semanticGrounding(semanticSignature: "semantic:objective", targets: [differentContainer])

        let firstFingerprint = try #require(TargetFingerprint.make(
            target: original,
            grounding: firstGrounding,
            stageId: "objective",
            expectedOutcome: .tileSelected
        ))
        let shiftedFingerprint = try #require(TargetFingerprint.make(
            target: shiftedCopy,
            grounding: shiftedGrounding,
            stageId: "objective",
            expectedOutcome: .tileSelected
        ))
        let differentFingerprint = try #require(TargetFingerprint.make(
            target: differentContainer,
            grounding: differentGrounding,
            stageId: "objective",
            expectedOutcome: .tileSelected
        ))

        #expect(firstFingerprint.isCompatible(with: shiftedFingerprint))
        #expect(!firstFingerprint.isCompatible(with: differentFingerprint))
    }

    @Test func temporalTrackingBlocksUnknownTargetAfterScreenChange() async throws {
        let point = guidePoint(expectedOutcome: .tileSelected)
        let response = guideResponse(
            semanticSignature: "semantic:objective",
            point: point,
            targets: [
                semanticTarget(elementId: "target", label: "Sales", state: "enabled", targetStability: "unknown"),
            ]
        )

        let decision = await GroundingSensorFusion.evaluate(
            guideResponse: response,
            guidePoint: point,
            screenCaptures: [syntheticScreenCapture()],
            screenChanged: true
        )

        #expect(decision.shouldBlockPoint)
        #expect(decision.contradictionReasons.contains(.targetStaleAfterScreenChange))
    }

    @Test func regionQualityBlocksImplausibleTargetBox() async throws {
        let point = guidePoint(expectedOutcome: .tileSelected)
        let response = guideResponse(
            semanticSignature: "semantic:objective",
            point: point,
            targets: [
                semanticTarget(
                    elementId: "target",
                    label: "Sales",
                    state: "enabled",
                    region: SpiderGuideRegion(x: 15, y: 15, width: 2, height: 2)
                ),
            ]
        )

        let decision = await GroundingSensorFusion.evaluate(
            guideResponse: response,
            guidePoint: point,
            screenCaptures: [syntheticScreenCapture()],
            screenChanged: false
        )

        #expect(decision.shouldBlockPoint)
        #expect(decision.evidence.regionQuality.regionPlausibility == .tooSmall)
        #expect(decision.contradictionReasons.contains(.regionImplausible))
    }

    @Test func actionRiskBlocksPublishBoundaryBeforeDot() async throws {
        let point = guidePoint(expectedOutcome: .screenAdvanced)
        let response = guideResponse(
            semanticSignature: "semantic:review",
            point: point,
            targets: [
                semanticTarget(
                    elementId: "publish",
                    label: "Publish",
                    state: "enabled"
                ),
            ],
            stageId: "publish_boundary"
        )

        let decision = await GroundingSensorFusion.evaluate(
            guideResponse: response,
            guidePoint: point,
            screenCaptures: [syntheticScreenCapture()],
            screenChanged: false
        )

        #expect(decision.shouldBlockPoint)
        #expect(decision.evidence.actionRisk == .publishBoundary)
        #expect(decision.contradictionReasons.contains(.actionRiskBlocked))
        #expect(decision.contradictionReasons.contains(.journeyTransitionInvalid))
    }
}
