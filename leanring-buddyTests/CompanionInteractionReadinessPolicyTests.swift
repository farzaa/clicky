//
//  CompanionInteractionReadinessPolicyTests.swift
//  leanring-buddyTests
//
//  Domain tests for account and permission gates before user-triggered work.
//

import Foundation
import Testing
@testable import Spider

@MainActor
struct CompanionInteractionReadinessPolicyTests {
    @Test func fullPermissionReadinessPrioritizesAccountBeforePermissions() {
        #expect(
            CompanionInteractionReadinessPolicy.fullPermissionReadiness(
                accountCanUseAI: false,
                allPermissionsGranted: false
            ) == .accountBlocked
        )
        #expect(
            CompanionInteractionReadinessPolicy.fullPermissionReadiness(
                accountCanUseAI: true,
                allPermissionsGranted: false
            ) == .permissionsBlocked
        )
        #expect(
            CompanionInteractionReadinessPolicy.fullPermissionReadiness(
                accountCanUseAI: true,
                allPermissionsGranted: true
            ) == .ready
        )
    }

    @Test func screenGuidanceReadinessKeepsAccountAndPermissionGatesSeparate() {
        #expect(
            CompanionInteractionReadinessPolicy.accountReadiness(accountCanUseAI: false) == .accountBlocked
        )
        #expect(
            CompanionInteractionReadinessPolicy.accountReadiness(accountCanUseAI: true) == .ready
        )
        #expect(
            CompanionInteractionReadinessPolicy.screenGuidancePermissionReadiness(
                hasScreenGuidancePermissions: false
            ) == .screenGuidanceBlocked
        )
        #expect(
            CompanionInteractionReadinessPolicy.screenGuidancePermissionReadiness(
                hasScreenGuidancePermissions: true
            ) == .ready
        )
    }

    @Test func readinessFlagIsOnlyTrueForReady() {
        #expect(CompanionInteractionReadinessPolicy.Decision.ready.isReady)
        #expect(!CompanionInteractionReadinessPolicy.Decision.accountBlocked.isReady)
        #expect(!CompanionInteractionReadinessPolicy.Decision.permissionsBlocked.isReady)
        #expect(!CompanionInteractionReadinessPolicy.Decision.screenGuidanceBlocked.isReady)
    }
}
