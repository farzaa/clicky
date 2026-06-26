//
//  CompanionKeyboardShortcutPolicy.swift
//  leanring-buddy
//
//  Pure timing rules for the global push-to-talk shortcut. A quick tap summons
//  Spider; holding the shortcut starts dictation after the delay below.
//

import Foundation

enum CompanionKeyboardShortcutPolicy {
    static let holdToTalkDelayNanoseconds: UInt64 = 260_000_000
    static let summonMaximumTapDuration: TimeInterval = 0.55

    struct ReleaseState: Equatable {
        let pressedAt: Date?
        let now: Date
        let didStartDictation: Bool
        let isSessionActiveOrFinalizing: Bool
        let isRecording: Bool
        let isPreparingToRecord: Bool
    }

    static func shouldSummonOnRelease(_ state: ReleaseState) -> Bool {
        guard let pressedAt = state.pressedAt else { return false }
        let pressDuration = state.now.timeIntervalSince(pressedAt)

        guard pressDuration <= summonMaximumTapDuration else { return false }
        guard !state.didStartDictation else { return false }
        guard !state.isSessionActiveOrFinalizing,
              !state.isRecording,
              !state.isPreparingToRecord else {
            return false
        }

        return true
    }
}
