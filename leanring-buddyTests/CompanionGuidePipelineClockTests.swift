//
//  CompanionGuidePipelineClockTests.swift
//  leanring-buddyTests
//
//  Tests for screen-guidance pipeline latency measurement.
//

import Foundation
import Testing
@testable import Spider

struct CompanionGuidePipelineClockTests {
    @Test func elapsedMillisecondsUsesWholeMilliseconds() {
        let startDate = Date(timeIntervalSince1970: 100)
        let now = startDate.addingTimeInterval(0.245)

        #expect(CompanionGuidePipelineClock.elapsedMilliseconds(since: startDate, now: now) == 245)
    }

    @Test func elapsedMillisecondsDoesNotReturnNegativeValues() {
        let startDate = Date(timeIntervalSince1970: 100)
        let now = startDate.addingTimeInterval(-1)

        #expect(CompanionGuidePipelineClock.elapsedMilliseconds(since: startDate, now: now) == 0)
    }
}
