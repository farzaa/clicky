//
//  DotIdleDetectorTests.swift
//  leanring-buddyTests
//
//  Sanity tests for the CGEventSource-backed idle detector. We can't
//  control real system idle time inside a unit test, so these tests are
//  intentionally narrow — they verify the API doesn't crash and returns
//  sensible values, not specific durations.
//

import Testing
import Foundation
@testable import leanring_buddy

@MainActor
struct DotIdleDetectorTests {

    @Test func secondsSinceLastInputReturnsNonNegative() {
        // The CGEventSource API should always be reachable on macOS during
        // a test run. Negative would indicate API unavailability.
        let measuredSeconds = DotIdleDetector.secondsSinceLastUserInputEvent()
        #expect(measuredSeconds != nil)
        if let actualSeconds = measuredSeconds {
            #expect(actualSeconds >= 0)
        }
    }

    @Test func hasUserBeenIdleReturnsFalseForUnreachableLongDuration() {
        // No realistic test run has 24h+ of continuous idle time. Anything
        // returning true here would indicate the API is broken or our
        // threshold logic is inverted.
        let twentyFourHours: TimeInterval = 24 * 60 * 60
        #expect(DotIdleDetector.hasUserBeenContinuouslyIdle(forAtLeast: twentyFourHours) == false)
    }

    @Test func hasUserBeenIdleAcceptsZeroAsTriviallyTrue() {
        // Threshold of 0 seconds — true iff the API returned a non-nil
        // value (i.e. the API is reachable). The second part of the
        // assertion documents that the threshold comparison is inclusive.
        let result = DotIdleDetector.hasUserBeenContinuouslyIdle(forAtLeast: 0)
        // This SHOULD be true unless the API is unavailable.
        #expect(result || DotIdleDetector.secondsSinceLastUserInputEvent() == nil)
    }
}
