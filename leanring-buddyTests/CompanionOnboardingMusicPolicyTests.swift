//
//  CompanionOnboardingMusicPolicyTests.swift
//  leanring-buddyTests
//
//  Domain tests for onboarding music timing constants.
//

import Foundation
import Testing
@testable import Spider

struct CompanionOnboardingMusicPolicyTests {
    @Test func musicPolicyKeepsExpectedResourceAndVolume() {
        #expect(CompanionOnboardingMusicPolicy.resourceName == "ff")
        #expect(CompanionOnboardingMusicPolicy.resourceExtension == "mp3")
        #expect(CompanionOnboardingMusicPolicy.initialVolume == 0.3)
    }

    @Test func fadeTimingIsStableAndEvenlyDivided() {
        #expect(CompanionOnboardingMusicPolicy.fadeDelayNanoseconds == 90_000_000_000)
        #expect(CompanionOnboardingMusicPolicy.fadeDurationNanoseconds == 3_000_000_000)
        #expect(CompanionOnboardingMusicPolicy.fadeSteps == 30)
        #expect(CompanionOnboardingMusicPolicy.fadeStepNanoseconds == 100_000_000)
    }
}
