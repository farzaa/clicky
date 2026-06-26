//
//  GuidedSetupPolicyTests.swift
//  leanring-buddyTests
//
//  Domain tests for guided setup prompts, polling, platform config, and presentation policy.
//

import Foundation
import Testing
@testable import Spider

@MainActor
struct GuidedSetupPolicyTests {
    @Test func promptComposerKeepsManualBoundariesExplicit() async throws {
        let currentScreenTranscript = GuidedSetupPromptComposer.currentScreenTranscript
        let pollTranscript = GuidedSetupPromptComposer.pollTranscript(pollIndex: 3)

        #expect(currentScreenTranscript.contains("Stop before Publish"))
        #expect(currentScreenTranscript.contains("Spider never spends"))
        #expect(pollTranscript.contains("Point only when the screen is recognized with high confidence"))
        #expect(pollTranscript.contains("Never point to billing, publish, budget edit"))
        #expect(pollTranscript.contains("Spider never clicks, never publishes, never changes budget"))
    }

    @Test func pollingPolicyUsesPreDotVerificationDelayFirst() async throws {
        var session = GuidedSetupSession(platformId: .metaAds)
        session.pendingPreDotVerification = PendingPreDotVerification(
            targetElementIdHash: nil,
            targetFingerprint: nil,
            regionQuality: RegionQuality(
                regionConfidence: .high,
                regionSource: .vision,
                regionStability: .stable,
                regionPlausibility: .plausible,
                pointInsideRegionConfidence: .high
            ),
            actionRisk: .selection,
            screenType: .cardTileSelection,
            stageType: .safeSetup,
            expectedOutcome: .tileSelected,
            semanticSignature: "semantic:objective",
            screenSignature: "screen:objective",
            requestedAt: Date(timeIntervalSince1970: 0),
            pollIndex: 1,
            reasons: [.targetNewOrUnknown]
        )

        let delay = GuidedSetupPollingPolicy.nextPollDelayNanoseconds(
            for: session,
            screenState: .recognized,
            suggestedPollAfterMs: 4_000
        )

        #expect(delay == GuidedSetupPollingPolicy.preDotVerificationPollDelayNanoseconds)
    }

    @Test func pollingPolicyRespectsBoundedWorkerSuggestion() async throws {
        let session = GuidedSetupSession(platformId: .metaAds)

        let safeSuggestedDelay = GuidedSetupPollingPolicy.nextPollDelayNanoseconds(
            for: session,
            screenState: .loading,
            suggestedPollAfterMs: 3_200
        )
        let tooFastSuggestedDelay = GuidedSetupPollingPolicy.nextPollDelayNanoseconds(
            for: session,
            screenState: .loading,
            suggestedPollAfterMs: 250
        )

        #expect(safeSuggestedDelay == 3_200_000_000)
        #expect(tooFastSuggestedDelay == GuidedSetupPollingPolicy.loadingPollDelayNanoseconds)
    }

    @Test func pollingPolicySlowsRepeatedLoadingAndStableRecognizedScreens() async throws {
        var repeatedLoading = GuidedSetupSession(platformId: .metaAds)
        repeatedLoading.consecutiveUnchangedCount = 2
        var stableRecognized = GuidedSetupSession(platformId: .metaAds)
        stableRecognized.consecutiveUnchangedCount = 1

        #expect(
            GuidedSetupPollingPolicy.nextPollDelayNanoseconds(
                for: repeatedLoading,
                screenState: .loading,
                suggestedPollAfterMs: nil
            ) == GuidedSetupPollingPolicy.followUpPollDelayNanoseconds
        )
        #expect(
            GuidedSetupPollingPolicy.nextPollDelayNanoseconds(
                for: stableRecognized,
                screenState: .recognized,
                suggestedPollAfterMs: nil
            ) == GuidedSetupPollingPolicy.unknownPollDelayNanoseconds
        )
    }

    @Test func pollingContinuationFinishesAtTheMaximumAutomaticPoll() async throws {
        let session = GuidedSetupSession(platformId: .metaAds)

        let decision = GuidedSetupPollingPolicy.continuationDecision(
            afterPollIndex: GuidedSetupPollingPolicy.maximumAutomaticPolls,
            for: session,
            screenState: .recognized,
            shouldContinuePolling: true,
            suggestedPollAfterMs: 2_000
        )

        #expect(decision == .finish(.maximumAutomaticPollsReached))
    }

    @Test func pollingContinuationHonorsWorkerStopWhenNoPreDotVerificationIsPending() async throws {
        let session = GuidedSetupSession(platformId: .metaAds)

        let decision = GuidedSetupPollingPolicy.continuationDecision(
            afterPollIndex: 3,
            for: session,
            screenState: .recognized,
            shouldContinuePolling: false,
            suggestedPollAfterMs: 2_000
        )

        #expect(decision == .finish(.workerStoppedPolling))
    }

    @Test func pollingContinuationKeepsPollingForPendingPreDotVerification() async throws {
        var session = GuidedSetupSession(platformId: .metaAds)
        session.pendingPreDotVerification = PendingPreDotVerification(
            targetElementIdHash: nil,
            targetFingerprint: nil,
            regionQuality: RegionQuality(
                regionConfidence: .high,
                regionSource: .vision,
                regionStability: .stable,
                regionPlausibility: .plausible,
                pointInsideRegionConfidence: .high
            ),
            actionRisk: .selection,
            screenType: .cardTileSelection,
            stageType: .safeSetup,
            expectedOutcome: .tileSelected,
            semanticSignature: "semantic:objective",
            screenSignature: "screen:objective",
            requestedAt: Date(timeIntervalSince1970: 0),
            pollIndex: 1,
            reasons: [.targetNewOrUnknown]
        )

        let decision = GuidedSetupPollingPolicy.continuationDecision(
            afterPollIndex: 3,
            for: session,
            screenState: .recognized,
            shouldContinuePolling: false,
            suggestedPollAfterMs: 2_000
        )

        #expect(decision == .continueAfter(GuidedSetupPollingPolicy.preDotVerificationPollDelayNanoseconds))
    }

    @Test func platformConfigurationPreservesMetaFallbackAndContextRules() async throws {
        let emptyConfiguration = AdPlatformGuideConfiguration.resolve(recommendedChannel: "")
        let metaConfiguration = AdPlatformGuideConfiguration.resolve(recommendedChannel: "Meta Ads")
        let googleConfiguration = AdPlatformGuideConfiguration.resolve(recommendedChannel: "Google Ads")

        #expect(emptyConfiguration.displayName == "Meta Ads")
        #expect(emptyConfiguration.launchURLString == "https://adsmanager.facebook.com/adsmanager/manage/campaigns")
        #expect(emptyConfiguration.platformContext == nil)
        #expect(emptyConfiguration.platformId == .unknown)
        #expect(metaConfiguration.platformContext == .metaAds())
        #expect(metaConfiguration.platformId == .metaAds)
        #expect(googleConfiguration.launchURLString == "https://ads.google.com/")
        #expect(googleConfiguration.platformContext == nil)
    }

    @Test func responsePresentationPolicyClassifiesLoadingConservatively() async throws {
        let explicitLoading = guideResponse(
            semanticSignature: "semantic:loading",
            point: nil,
            targets: [],
            screenState: .loading
        )
        let textualLoading = guideResponse(
            semanticSignature: "semantic:loading-text",
            point: nil,
            targets: [],
            spokenText: "Still loading.",
            displayText: "Carregando",
            nextStep: "Wait",
            screenState: nil
        )
        let explicitRecognized = guideResponse(
            semanticSignature: "semantic:recognized",
            point: nil,
            targets: [],
            spokenText: "Loading is done.",
            displayText: "Loading finished",
            nextStep: "Continue",
            screenState: .recognized
        )

        #expect(GuideResponsePresentationPolicy.isLoading(explicitLoading))
        #expect(GuideResponsePresentationPolicy.isLoading(textualLoading))
        #expect(!GuideResponsePresentationPolicy.isLoading(explicitRecognized))
        #expect(GuideResponsePresentationPolicy.resolvedScreenState(for: explicitLoading) == .loading)
        #expect(GuideResponsePresentationPolicy.resolvedScreenState(for: textualLoading) == .loading)
        #expect(GuideResponsePresentationPolicy.resolvedScreenState(for: explicitRecognized) == .recognized)
    }

    @Test func responsePresentationPolicyInfersScreenStateConservatively() async throws {
        let unknownContextResponse = guideResponse(
            semanticSignature: "semantic:unknown",
            point: nil,
            targets: [],
            screenState: nil,
            contextKind: .unclear
        )
        let manualConfirmationResponse = guideResponse(
            semanticSignature: "semantic:blocked",
            point: nil,
            targets: [],
            screenState: nil,
            requiresManualConfirmation: true
        )
        let recognizedFallbackResponse = guideResponse(
            semanticSignature: "semantic:recognized",
            point: nil,
            targets: [],
            screenState: nil
        )

        #expect(GuideResponsePresentationPolicy.resolvedScreenState(for: unknownContextResponse) == .unknown)
        #expect(GuideResponsePresentationPolicy.resolvedScreenState(for: manualConfirmationResponse) == .blocked)
        #expect(GuideResponsePresentationPolicy.resolvedScreenState(for: recognizedFallbackResponse) == .recognized)
    }

    @Test func responsePresentationPolicySuppressesAutomaticNoise() async throws {
        let unknownResponse = guideResponse(
            semanticSignature: "semantic:unknown",
            point: nil,
            targets: [],
            screenState: .unknown
        )
        let loadingResponse = guideResponse(
            semanticSignature: "semantic:loading",
            point: nil,
            targets: [],
            screenState: .loading
        )

        #expect(
            GuideResponsePresentationPolicy.shouldSpeak(
                unknownResponse,
                resolvedScreenState: .unknown,
                isAutomaticScreenRefresh: false,
                screenChanged: false
            )
        )
        #expect(
            !GuideResponsePresentationPolicy.shouldSpeak(
                unknownResponse,
                resolvedScreenState: .unknown,
                isAutomaticScreenRefresh: true,
                screenChanged: false
            )
        )
        #expect(
            !GuideResponsePresentationPolicy.shouldSpeak(
                loadingResponse,
                resolvedScreenState: .loading,
                isAutomaticScreenRefresh: true,
                screenChanged: true
            )
        )
        #expect(
            GuideResponsePresentationPolicy.shouldShowStatusBubble(
                unknownResponse,
                resolvedScreenState: .unknown,
                isAutomaticScreenRefresh: true,
                screenChanged: true,
                suppressRepeatedBubble: false
            )
        )
        #expect(
            !GuideResponsePresentationPolicy.shouldShowStatusBubble(
                unknownResponse,
                resolvedScreenState: .unknown,
                isAutomaticScreenRefresh: true,
                screenChanged: true,
                suppressRepeatedBubble: true
            )
        )
        #expect(
            !GuideResponsePresentationPolicy.shouldShowStatusBubble(
                loadingResponse,
                resolvedScreenState: .loading,
                isAutomaticScreenRefresh: true,
                screenChanged: true,
                suppressRepeatedBubble: false
            )
        )
    }
}
