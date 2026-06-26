//
//  CompanionOnboardingPromptPolicyTests.swift
//  leanring-buddyTests
//
//  Domain tests for onboarding prompt copy and timing constants.
//

import Foundation
import Testing
@testable import Spider

struct CompanionOnboardingPromptPolicyTests {
    @Test func promptPolicyKeepsExistingCopy() {
        #expect(CompanionOnboardingPromptPolicy.message == "tap control + option + space to show spider")
    }

    @Test func promptPolicyKeepsExistingTiming() {
        #expect(CompanionOnboardingPromptPolicy.fadeInDurationSeconds == 0.4)
        #expect(CompanionOnboardingPromptPolicy.typingIntervalSeconds == 0.03)
        #expect(CompanionOnboardingPromptPolicy.autoDismissDelaySeconds == 10.0)
        #expect(CompanionOnboardingPromptPolicy.fadeOutDurationSeconds == 0.3)
        #expect(CompanionOnboardingPromptPolicy.teardownDelaySeconds == 0.35)
    }
}
