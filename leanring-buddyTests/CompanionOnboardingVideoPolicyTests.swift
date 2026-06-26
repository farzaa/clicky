//
//  CompanionOnboardingVideoPolicyTests.swift
//  leanring-buddyTests
//
//  Domain tests for onboarding video timing constants.
//

import AVFoundation
import Foundation
import Testing
@testable import Spider

struct CompanionOnboardingVideoPolicyTests {
    @Test func videoPolicyKeepsExistingStreamAndDemoTiming() {
        #expect(CompanionOnboardingVideoPolicy.streamURLString.contains("stream.mux.com"))
        #expect(CompanionOnboardingVideoPolicy.mountDelaySeconds == 0.2)
        #expect(CompanionOnboardingVideoPolicy.demoTriggerSeconds == 40)
        #expect(CompanionOnboardingVideoPolicy.demoTriggerPreferredTimescale == 600)
        #expect(
            CompanionOnboardingVideoPolicy.demoTriggerTime
                == CMTime(seconds: 40, preferredTimescale: 600)
        )
    }

    @Test func videoPolicyKeepsExistingFadeAndPromptTiming() {
        #expect(CompanionOnboardingVideoPolicy.audioFadeTargetVolume == 1.0)
        #expect(CompanionOnboardingVideoPolicy.audioFadeDurationSeconds == 2.0)
        #expect(CompanionOnboardingVideoPolicy.audioFadeSteps == 20)
        #expect(CompanionOnboardingVideoPolicy.videoFadeOutDurationSeconds == 2.0)
        #expect(CompanionOnboardingVideoPolicy.promptDelayAfterVideoSeconds == 0.3)
    }
}
