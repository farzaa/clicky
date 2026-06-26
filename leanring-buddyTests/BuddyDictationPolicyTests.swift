//
//  BuddyDictationPolicyTests.swift
//  leanring-buddyTests
//
//  Domain tests for push-to-talk dictation policies kept outside the manager.
//

import CoreGraphics
import Foundation
import Testing
@testable import Spider

struct BuddyDictationPolicyTests {
    @Test func draftComposerPreservesExistingSpacingRules() {
        #expect(
            BuddyDictationDraftComposer.compose(
                existingDraftText: "",
                transcribedText: "  launch the campaign  "
            ) == "launch the campaign"
        )
        #expect(
            BuddyDictationDraftComposer.compose(
                existingDraftText: "Review objective",
                transcribedText: "choose sales"
            ) == "Review objective choose sales"
        )
        #expect(
            BuddyDictationDraftComposer.compose(
                existingDraftText: "Review objective ",
                transcribedText: "choose sales"
            ) == "Review objective choose sales"
        )
        #expect(
            BuddyDictationDraftComposer.compose(
                existingDraftText: "Review objective\n",
                transcribedText: "choose sales"
            ) == "Review objective\nchoose sales"
        )
        #expect(
            BuddyDictationDraftComposer.compose(
                existingDraftText: "Keep current draft",
                transcribedText: "   "
            ) == "Keep current draft"
        )
    }

    @Test func audioPowerMeterKeepsWaveformBoundedAndStable() {
        let baselineHistory = BuddyDictationAudioPowerMeter.baselineHistory()
        #expect(baselineHistory.count == BuddyDictationAudioPowerMeter.historyLength)
        #expect(baselineHistory.allSatisfy { $0 == BuddyDictationAudioPowerMeter.baselineLevel })

        let smoothedLevel = BuddyDictationAudioPowerMeter.smoothedLevel(
            currentLevel: 0.5,
            boostedLevel: 0.1
        )
        #expect(smoothedLevel == 0.36)

        let appendedHistory = BuddyDictationAudioPowerMeter.history(
            afterAppending: 0.8,
            to: baselineHistory
        )
        #expect(appendedHistory.count == BuddyDictationAudioPowerMeter.historyLength)
        #expect(appendedHistory.last == 0.8)
        #expect(appendedHistory.first == BuddyDictationAudioPowerMeter.baselineLevel)
    }

    @Test func audioPowerMeterSamplesOnConfiguredCadence() {
        let now = Date(timeIntervalSince1970: 1_000)

        #expect(
            !BuddyDictationAudioPowerMeter.shouldRecordSample(
                lastSampledAt: now.addingTimeInterval(-0.03),
                now: now
            )
        )
        #expect(
            BuddyDictationAudioPowerMeter.shouldRecordSample(
                lastSampledAt: now.addingTimeInterval(-0.07),
                now: now
            )
        )
    }
}
