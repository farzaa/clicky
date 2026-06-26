//
//  CompanionKeyboardShortcutPolicyTests.swift
//  leanring-buddyTests
//
//  Domain tests for tap-to-summon versus hold-to-talk shortcut timing.
//

import Foundation
import Testing
@testable import Spider

struct CompanionKeyboardShortcutPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_000)

    @Test func quickReleaseBeforeDictationSummonsSpider() {
        let state = CompanionKeyboardShortcutPolicy.ReleaseState(
            pressedAt: now.addingTimeInterval(-0.2),
            now: now,
            didStartDictation: false,
            isSessionActiveOrFinalizing: false,
            isRecording: false,
            isPreparingToRecord: false
        )

        #expect(CompanionKeyboardShortcutPolicy.shouldSummonOnRelease(state))
    }

    @Test func longPressDoesNotSummonSpider() {
        let state = CompanionKeyboardShortcutPolicy.ReleaseState(
            pressedAt: now.addingTimeInterval(-0.8),
            now: now,
            didStartDictation: false,
            isSessionActiveOrFinalizing: false,
            isRecording: false,
            isPreparingToRecord: false
        )

        #expect(!CompanionKeyboardShortcutPolicy.shouldSummonOnRelease(state))
    }

    @Test func releaseAfterDictationStartsDoesNotSummonSpider() {
        let state = CompanionKeyboardShortcutPolicy.ReleaseState(
            pressedAt: now.addingTimeInterval(-0.2),
            now: now,
            didStartDictation: true,
            isSessionActiveOrFinalizing: false,
            isRecording: false,
            isPreparingToRecord: false
        )

        #expect(!CompanionKeyboardShortcutPolicy.shouldSummonOnRelease(state))
    }

    @Test func activeAudioStatesBlockSummon() {
        let activeStates = [
            CompanionKeyboardShortcutPolicy.ReleaseState(
                pressedAt: now.addingTimeInterval(-0.2),
                now: now,
                didStartDictation: false,
                isSessionActiveOrFinalizing: true,
                isRecording: false,
                isPreparingToRecord: false
            ),
            CompanionKeyboardShortcutPolicy.ReleaseState(
                pressedAt: now.addingTimeInterval(-0.2),
                now: now,
                didStartDictation: false,
                isSessionActiveOrFinalizing: false,
                isRecording: true,
                isPreparingToRecord: false
            ),
            CompanionKeyboardShortcutPolicy.ReleaseState(
                pressedAt: now.addingTimeInterval(-0.2),
                now: now,
                didStartDictation: false,
                isSessionActiveOrFinalizing: false,
                isRecording: false,
                isPreparingToRecord: true
            )
        ]

        for state in activeStates {
            #expect(!CompanionKeyboardShortcutPolicy.shouldSummonOnRelease(state))
        }
    }

    @Test func missingPressTimestampDoesNotSummonSpider() {
        let state = CompanionKeyboardShortcutPolicy.ReleaseState(
            pressedAt: nil,
            now: now,
            didStartDictation: false,
            isSessionActiveOrFinalizing: false,
            isRecording: false,
            isPreparingToRecord: false
        )

        #expect(!CompanionKeyboardShortcutPolicy.shouldSummonOnRelease(state))
    }
}
