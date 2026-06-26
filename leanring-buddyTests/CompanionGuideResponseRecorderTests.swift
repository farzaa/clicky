//
//  CompanionGuideResponseRecorderTests.swift
//  leanring-buddyTests
//
//  Tests for guide-response state recording and local Ad Mission persistence.
//

import Foundation
import Testing
@testable import Spider

private enum CompanionGuideResponseRecorderTestError: Error {
    case saveFailed
}

struct CompanionGuideResponseRecorderTests {
    @Test func recordsBoundedConversationHistoryForNextGuideRequest() {
        var recorder = CompanionGuideResponseRecorder(saveStore: { _ in })
        var mission = AdMission.empty()
        let totalTurns = SpiderContentLimits.maxVisionConversationHistoryTurns + 2

        for index in 1...totalTurns {
            recorder.record(
                guideResponse(
                    semanticSignature: "screen-\(index)",
                    point: nil,
                    targets: [],
                    displayText: "assistant \(index)"
                ),
                userTranscript: "user \(index)",
                adMission: &mission
            )
        }

        #expect(recorder.conversationTurns.count == SpiderContentLimits.maxVisionConversationHistoryTurns)
        #expect(recorder.conversationTurns.first?.userTranscript == "user 3")
        #expect(recorder.conversationTurns.last?.assistantResponse == "assistant \(totalTurns)")

        recorder.removeAllConversationContext()

        #expect(recorder.conversationTurns.isEmpty)
    }

    @Test func appliesGuideResponseMissionSideEffectsThroughLocalPersistence() {
        var savedMissions: [AdMission] = []
        var recorder = CompanionGuideResponseRecorder(
            saveStore: { mission in
                savedMissions.append(mission)
            }
        )
        var mission = AdMission.empty()

        recorder.record(
            guideResponse(
                semanticSignature: "recognized",
                point: nil,
                targets: [],
                displayText: "Choose Sales.",
                decisionMemoryUpdate: "Keep budget manual.",
                adMissionUpdate: AdMissionUpdate(
                    offer: "  Course  ",
                    targetAudience: "  Founders  ",
                    ticket: "$99",
                    country: "US",
                    language: "English",
                    budget: "$20/day",
                    businessObjective: "sell product",
                    landingPageURL: "https://example.com",
                    recommendedChannel: "Meta Ads",
                    campaignPlan: "Stop before Publish.",
                    decisions: ["Choose Sales."],
                    reviewSchedule: "Manual review only."
                ),
                artifact: SpiderArtifact(
                    kind: .campaignPlan,
                    title: "  Campaign Plan  ",
                    markdown: "  Stop before Publish.  "
                )
            ),
            userTranscript: "private user transcript",
            adMission: &mission
        )

        #expect(savedMissions.count == 3)
        #expect(mission.offer == "Course")
        #expect(mission.targetAudience == "Founders")
        #expect(mission.recommendedChannel == "Meta Ads")
        #expect(mission.campaignPlan == "Stop before Publish.")
        #expect(mission.decisions == ["Choose Sales.", "Keep budget manual."])
        #expect(mission.artifacts.count == 1)
        #expect(mission.artifacts.first?.kind == .campaignPlan)
        #expect(mission.artifacts.first?.title == "Campaign Plan")
        #expect(mission.artifacts.first?.markdown == "Stop before Publish.")
        #expect(recorder.conversationTurns.count == 1)
    }

    @Test func failedPersistenceDoesNotMutateMissionButStillRecordsConversationContext() {
        var recorder = CompanionGuideResponseRecorder(
            saveStore: { _ in throw CompanionGuideResponseRecorderTestError.saveFailed }
        )
        var mission = AdMission.empty()

        recorder.record(
            guideResponse(
                semanticSignature: "recognized",
                point: nil,
                targets: [],
                displayText: "Choose Sales.",
                adMissionUpdate: AdMissionUpdate(
                    offer: "Course",
                    targetAudience: nil,
                    ticket: nil,
                    country: nil,
                    language: nil,
                    budget: nil,
                    businessObjective: nil,
                    landingPageURL: nil,
                    recommendedChannel: nil,
                    campaignPlan: nil,
                    decisions: nil,
                    reviewSchedule: nil
                )
            ),
            userTranscript: "private user transcript",
            adMission: &mission
        )

        #expect(mission.offer.isEmpty)
        #expect(recorder.conversationTurns.count == 1)
        #expect(recorder.conversationTurns.first?.assistantResponse == "Choose Sales.")
    }
}
