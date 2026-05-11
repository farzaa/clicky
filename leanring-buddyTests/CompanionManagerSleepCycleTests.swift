//
//  CompanionManagerSleepCycleTests.swift
//  leanring-buddyTests
//
//  Pure-logic tests for `CompanionManager.evaluateSleepCycleReadinessFromInputs`.
//  The function is the gate between "the scheduler woke up" and "we're
//  about to spend tokens on a Haiku consolidation pass," so getting its
//  branches right matters — under-firing means stale memory accumulates;
//  over-firing means wasted tokens and a worse user experience.
//

import Testing
import Foundation
@testable import leanring_buddy

@MainActor
struct CompanionManagerSleepCycleTests {

    // Real production constants (kept in sync with CompanionManager).
    // We verify the pure helper behaves as documented; if these constants
    // change, update the literals below.
    private static let productionRequiredIdleSecondsLowerBound: TimeInterval = 30 * 60
    private static let productionMinSecondsBetweenRuns: TimeInterval = 24 * 60 * 60

    // MARK: - Pass-already-in-flight gate

    @Test func skipsWhenPassAlreadyInFlight() {
        let decision = CompanionManager.evaluateSleepCycleReadinessFromInputs(
            isSleepCyclePassAlreadyInFlight: true,
            measuredIdleSeconds: 99 * 60,
            secondsSinceLastSleepCycleRun: 99 * 60 * 60,
            turnsSinceLastSleepCycleRun: 999
        )
        #expect(decision == .skipPassAlreadyInFlight)
    }

    // MARK: - Idle detector unavailable

    @Test func skipsWhenIdleDetectorReturnsNil() {
        let decision = CompanionManager.evaluateSleepCycleReadinessFromInputs(
            isSleepCyclePassAlreadyInFlight: false,
            measuredIdleSeconds: nil,
            secondsSinceLastSleepCycleRun: 99 * 60 * 60,
            turnsSinceLastSleepCycleRun: 999
        )
        #expect(decision == .skipIdleDetectorUnavailable)
    }

    // MARK: - Idle threshold

    @Test func skipsWhenUserIsActivelyUsingTheMachine() {
        // 30 seconds of idle is nowhere near the 30-min threshold.
        let decision = CompanionManager.evaluateSleepCycleReadinessFromInputs(
            isSleepCyclePassAlreadyInFlight: false,
            measuredIdleSeconds: 30,
            secondsSinceLastSleepCycleRun: 99 * 60 * 60,
            turnsSinceLastSleepCycleRun: 999
        )
        if case .skipNotIdleEnough(let currentIdle, let requiredIdle) = decision {
            #expect(currentIdle == 30)
            #expect(requiredIdle >= Self.productionRequiredIdleSecondsLowerBound)
        } else {
            Issue.record("expected skipNotIdleEnough, got \(decision)")
        }
    }

    @Test func skipsAtExactlyOneSecondBelowIdleThreshold() {
        // Boundary check: 30min - 1s should still be "not idle enough".
        let decision = CompanionManager.evaluateSleepCycleReadinessFromInputs(
            isSleepCyclePassAlreadyInFlight: false,
            measuredIdleSeconds: Self.productionRequiredIdleSecondsLowerBound - 1,
            secondsSinceLastSleepCycleRun: 99 * 60 * 60,
            turnsSinceLastSleepCycleRun: 999
        )
        if case .skipNotIdleEnough = decision {
            // Expected.
        } else {
            Issue.record("expected skipNotIdleEnough at threshold-1, got \(decision)")
        }
    }

    // MARK: - Cooldown

    @Test func skipsWhenLastRunWasOnlyAFewMinutesAgo() {
        // User idle for an hour but last consolidation was 5 min ago.
        let decision = CompanionManager.evaluateSleepCycleReadinessFromInputs(
            isSleepCyclePassAlreadyInFlight: false,
            measuredIdleSeconds: 60 * 60,
            secondsSinceLastSleepCycleRun: 5 * 60,
            turnsSinceLastSleepCycleRun: 999
        )
        if case .skipCooldownNotMet(let secondsRemaining) = decision {
            #expect(secondsRemaining > 0)
            #expect(secondsRemaining < Self.productionMinSecondsBetweenRuns)
        } else {
            Issue.record("expected skipCooldownNotMet, got \(decision)")
        }
    }

    @Test func skipsAtExactlyOneSecondBelowCooldownThreshold() {
        // 24h - 1s since last run; should still be in cooldown.
        let decision = CompanionManager.evaluateSleepCycleReadinessFromInputs(
            isSleepCyclePassAlreadyInFlight: false,
            measuredIdleSeconds: 60 * 60,
            secondsSinceLastSleepCycleRun: Self.productionMinSecondsBetweenRuns - 1,
            turnsSinceLastSleepCycleRun: 999
        )
        if case .skipCooldownNotMet = decision {
            // Expected.
        } else {
            Issue.record("expected skipCooldownNotMet at threshold-1, got \(decision)")
        }
    }

    // MARK: - Turn floor

    @Test func skipsWhenTooFewTurnsSinceLastRun() {
        // User is idle, cooldown is met, but only 2 turns have happened.
        // Don't bother spending Haiku tokens for a near-empty review.
        let decision = CompanionManager.evaluateSleepCycleReadinessFromInputs(
            isSleepCyclePassAlreadyInFlight: false,
            measuredIdleSeconds: 60 * 60,
            secondsSinceLastSleepCycleRun: Self.productionMinSecondsBetweenRuns + 1,
            turnsSinceLastSleepCycleRun: 2
        )
        if case .skipNotEnoughTurns(let observed, let required) = decision {
            #expect(observed == 2)
            #expect(required >= 5)
        } else {
            Issue.record("expected skipNotEnoughTurns, got \(decision)")
        }
    }

    // MARK: - All gates pass

    @Test func returnsReadyWhenAllGatesPass() {
        let decision = CompanionManager.evaluateSleepCycleReadinessFromInputs(
            isSleepCyclePassAlreadyInFlight: false,
            measuredIdleSeconds: 60 * 60,
            secondsSinceLastSleepCycleRun: Self.productionMinSecondsBetweenRuns + 1,
            turnsSinceLastSleepCycleRun: 50
        )
        #expect(decision == .ready)
    }

    @Test func returnsReadyAtExactBoundaryConditions() {
        // Boundaries should be inclusive (>= not >).
        let decision = CompanionManager.evaluateSleepCycleReadinessFromInputs(
            isSleepCyclePassAlreadyInFlight: false,
            measuredIdleSeconds: Self.productionRequiredIdleSecondsLowerBound,
            secondsSinceLastSleepCycleRun: Self.productionMinSecondsBetweenRuns,
            turnsSinceLastSleepCycleRun: 5
        )
        #expect(decision == .ready)
    }

    // MARK: - Realistic scenarios

    @Test func scenarioActiveDayDoesNotTrigger() {
        // User is talking to dot all day, never idle for >30min.
        let decision = CompanionManager.evaluateSleepCycleReadinessFromInputs(
            isSleepCyclePassAlreadyInFlight: false,
            measuredIdleSeconds: 5 * 60,    // talking every 5 min
            secondsSinceLastSleepCycleRun: 50 * 60 * 60,  // hasn't run in 2 days
            turnsSinceLastSleepCycleRun: 80               // many turns accumulated
        )
        if case .skipNotIdleEnough = decision {
            // Expected — user activity wins.
        } else {
            Issue.record("an actively-using user should not trigger sleep cycle, got \(decision)")
        }
    }

    @Test func scenarioOvernightSleepTriggers() {
        // User went to bed at 11pm; it's now 7am. 8 hours idle, 8h since
        // last run (skipped previous attempt because cooldown), plenty of
        // turns.
        let decision = CompanionManager.evaluateSleepCycleReadinessFromInputs(
            isSleepCyclePassAlreadyInFlight: false,
            measuredIdleSeconds: 8 * 60 * 60,
            secondsSinceLastSleepCycleRun: 25 * 60 * 60,  // last run >24h ago
            turnsSinceLastSleepCycleRun: 30
        )
        #expect(decision == .ready)
    }

    @Test func scenarioJustWokeUpDoesNotTrigger() {
        // User typed 2 seconds ago — definitely not idle. Even if all
        // other conditions are met, idle gate wins.
        let decision = CompanionManager.evaluateSleepCycleReadinessFromInputs(
            isSleepCyclePassAlreadyInFlight: false,
            measuredIdleSeconds: 2,
            secondsSinceLastSleepCycleRun: 99 * 60 * 60,
            turnsSinceLastSleepCycleRun: 999
        )
        if case .skipNotIdleEnough = decision {
            // Expected.
        } else {
            Issue.record("expected idle gate to dominate, got \(decision)")
        }
    }

    @Test func scenarioFreshInstallDoesNotTrigger() {
        // No turns yet — fresh user, no memory state to consolidate.
        let decision = CompanionManager.evaluateSleepCycleReadinessFromInputs(
            isSleepCyclePassAlreadyInFlight: false,
            measuredIdleSeconds: 10 * 60 * 60,
            secondsSinceLastSleepCycleRun: 99 * 60 * 60,
            turnsSinceLastSleepCycleRun: 0
        )
        if case .skipNotEnoughTurns = decision {
            // Expected.
        } else {
            Issue.record("expected skipNotEnoughTurns for fresh install, got \(decision)")
        }
    }
}
