//
//  GuidedSetupScreenIdentityResolverTests.swift
//  leanring-buddyTests
//
//  Domain tests for guided setup screen/stage identity resolution.
//

import Foundation
import Testing
@testable import Spider

struct GuidedSetupScreenIdentityResolverTests {
    @Test func currentIdentityPreservesNonEmptyWorkerIdentifiers() {
        let response = guideResponse(
            semanticSignature: "semantic:objective",
            point: nil,
            targets: [],
            screenId: "objective_selection",
            stageId: "objective"
        )

        let identity = GuidedSetupScreenIdentityResolver.currentIdentity(
            from: response,
            resolvedScreenState: .recognized
        )

        #expect(identity.screenId == "objective_selection")
        #expect(identity.stageId == "objective")
    }

    @Test func currentIdentityFallsBackByScreenStateWhenWorkerIdentifiersAreEmpty() {
        let response = guideResponse(
            semanticSignature: "semantic:loading",
            point: nil,
            targets: [],
            screenState: .loading,
            screenId: "",
            stageId: ""
        )

        let identity = GuidedSetupScreenIdentityResolver.currentIdentity(
            from: response,
            resolvedScreenState: .loading
        )

        #expect(identity.screenId == "loading_screen")
        #expect(identity.stageId == "loading")
    }

    @Test func sanitizedOutcomeIdentityBoundsWorkerIdentifiersBeforeOutcomeComparison() {
        let response = guideResponse(
            semanticSignature: "semantic:blocked",
            point: nil,
            targets: [],
            screenState: .blocked,
            screenId: "billing_payment\nprivate trailing text",
            stageId: "billing\tpayment"
        )

        let identity = GuidedSetupScreenIdentityResolver.sanitizedOutcomeIdentity(
            from: response,
            resolvedScreenState: .blocked
        )

        #expect(!identity.screenId.contains("\n"))
        #expect(!identity.stageId.contains("\t"))
        #expect(identity.screenId.hasPrefix("billing_payment"))
        #expect(identity.stageId.hasPrefix("billing"))
    }

    @Test func fallbackIdentityCoversAllScreenStates() {
        #expect(GuidedSetupScreenIdentityResolver.fallbackScreenId(for: .loading) == "loading_screen")
        #expect(GuidedSetupScreenIdentityResolver.fallbackStageId(for: .loading) == "loading")
        #expect(GuidedSetupScreenIdentityResolver.fallbackScreenId(for: .unknown) == "unknown_screen")
        #expect(GuidedSetupScreenIdentityResolver.fallbackStageId(for: .unknown) == "unknown_stage")
        #expect(GuidedSetupScreenIdentityResolver.fallbackScreenId(for: .recognized) == "recognized_screen")
        #expect(GuidedSetupScreenIdentityResolver.fallbackStageId(for: .recognized) == "recognized_stage")
        #expect(GuidedSetupScreenIdentityResolver.fallbackScreenId(for: .blocked) == "blocked_screen")
        #expect(GuidedSetupScreenIdentityResolver.fallbackStageId(for: .blocked) == "blocked_stage")
    }
}
