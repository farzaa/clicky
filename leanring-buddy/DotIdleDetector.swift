//
//  DotIdleDetector.swift
//  leanring-buddy
//
//  Thin wrapper around the macOS Quartz "seconds since last input event"
//  API. Used by the sleep-cycle scheduler to decide when the user has
//  stepped away from the keyboard long enough that running a Haiku-backed
//  consolidation pass won't introduce visible latency.
//

import CoreGraphics
import Foundation

enum DotIdleDetector {
    /// Returns the number of seconds since the user last touched the
    /// keyboard, mouse, trackpad, or any other input device system-wide.
    /// Resets to 0 on every new input event. Returns nil if the API is
    /// unavailable (shouldn't happen on macOS but defensive).
    static func secondsSinceLastUserInputEvent() -> TimeInterval? {
        // The C constant `kCGAnyInputEventType` is `((CGEventType)~0)` and
        // means "any input event." Swift bridges CGEventType as an enum
        // and doesn't expose a named "any" case, but the numeric value
        // 0xFFFFFFFF is the underlying sentinel the API recognizes — it
        // happens to coincide with the named case
        // .tapDisabledByUserInput, but the API ignores the case identity
        // and reads the raw value as the "match anything" wildcard.
        guard let anyInputEventTypeWildcard = CGEventType(rawValue: 0xFFFFFFFF) else {
            return nil
        }
        // CGEventSourceStateID.combinedSessionState aggregates events from
        // all sources (HID + posted) so synthetic events from our own
        // CompanionComputerController DO count as "user activity" — this
        // is desirable: we don't want to start a sleep-cycle pass while
        // an agent action sequence is mid-flight even if the human isn't
        // physically touching the keyboard.
        let secondsSinceLastEvent = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: anyInputEventTypeWildcard
        )
        // Negative = API unavailable / clock not yet initialized. Zero is
        // valid (an event JUST fired), so we let it through.
        guard secondsSinceLastEvent >= 0 else { return nil }
        return secondsSinceLastEvent
    }

    /// True iff the user has been continuously idle for at least
    /// `requiredIdleSeconds`. Wraps the read above so callers don't have
    /// to handle the optional themselves.
    static func hasUserBeenContinuouslyIdle(forAtLeast requiredIdleSeconds: TimeInterval) -> Bool {
        guard let measuredIdleSeconds = secondsSinceLastUserInputEvent() else {
            return false
        }
        return measuredIdleSeconds >= requiredIdleSeconds
    }
}
