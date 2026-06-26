//
//  CompanionGuidanceStatusBubblePolicyTests.swift
//  leanring-buddyTests
//
//  Domain tests for transient guidance status bubble presentation policy.
//

import Foundation
import Testing
@testable import Spider

struct CompanionGuidanceStatusBubblePolicyTests {
    @Test func statusBubblePolicyKeepsExistingBoundsAndTiming() {
        #expect(CompanionGuidanceStatusBubblePolicy.maxCharacters == 64)
        #expect(CompanionGuidanceStatusBubblePolicy.maxWords == 8)
        #expect(CompanionGuidanceStatusBubblePolicy.maxSentences == 1)
        #expect(CompanionGuidanceStatusBubblePolicy.hideDelaySeconds == 2.4)
    }

    @Test func statusBubblePolicySanitizesVisibleText() {
        let sanitizedText = CompanionGuidanceStatusBubblePolicy.sanitizedText(
            "  one two three four five six seven eight nine. second sentence.  "
        )

        #expect(sanitizedText == "one two three four five six seven eight")
        #expect(CompanionGuidanceStatusBubblePolicy.sanitizedText("   ") == "")
    }
}
