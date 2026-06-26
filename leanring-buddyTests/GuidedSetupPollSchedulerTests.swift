//
//  GuidedSetupPollSchedulerTests.swift
//  leanring-buddyTests
//
//  Tests automatic guided setup poll task ownership without touching session state.
//

import Testing
@testable import Spider

@MainActor
struct GuidedSetupPollSchedulerTests {
    @Test func scheduleRunsThePollAction() async {
        let scheduler = GuidedSetupPollScheduler()
        var runCount = 0

        let task = scheduler.schedule(after: 0) {
            runCount += 1
        }
        await task.value

        #expect(runCount == 1)
    }

    @Test func cancelPreventsPendingPollAction() async {
        let scheduler = GuidedSetupPollScheduler()
        var runCount = 0

        let task = scheduler.schedule(after: UInt64.max) {
            runCount += 1
        }
        scheduler.cancelPendingPoll()
        await task.value

        #expect(runCount == 0)
    }

    @Test func schedulingANewPollCancelsThePreviousPoll() async {
        let scheduler = GuidedSetupPollScheduler()
        var runOrder: [String] = []

        let firstTask = scheduler.schedule(after: UInt64.max) {
            runOrder.append("first")
        }
        let secondTask = scheduler.schedule(after: 0) {
            runOrder.append("second")
        }
        await firstTask.value
        await secondTask.value

        #expect(runOrder == ["second"])
    }
}
