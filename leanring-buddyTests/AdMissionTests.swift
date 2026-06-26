//
//  AdMissionTests.swift
//  leanring-buddyTests
//
//  Domain tests for local Ad Mission planning, lifecycle, and update rules.
//

import Foundation
import Testing
@testable import Spider

private enum AdMissionTestSaveError: Error {
    case failed
}

@MainActor
struct AdMissionTests {
    @Test func campaignPlannerKeepsManualPublishBoundaryInPlan() async throws {
        let draft = AdMissionOfferDraft(
            offer: "Course",
            audience: "Founders",
            ticket: "$99",
            country: "US",
            language: "English",
            budget: "$20/day",
            businessGoal: "sell product",
            landingPageURL: "https://example.com",
            experienceLevel: "beginner",
            recommendedChannel: "Meta Ads"
        )
        let direction = AdMissionCampaignPlanner.direction(for: draft)
        let planMarkdown = AdMissionCampaignPlanner.planMarkdown(for: draft, direction: direction)

        #expect(direction.recommendedObjective == "Sales")
        #expect(direction.nextStep == "Open Meta Ads, create a campaign, choose Sales, and stop before Publish.")
        #expect(planMarkdown.contains("## Budget boundary"))
        #expect(planMarkdown.contains("Keep the campaign inside $20/day. Do not increase budget before you have signal."))
        #expect(planMarkdown.contains("## Do not touch yet"))
        #expect(planMarkdown.contains("- Budget scaling"))
        #expect(planMarkdown.contains("Purchase, if available. If not, fix tracking before publishing."))
    }

    @Test func campaignPlannerFallsBackToMetaAndLeadObjective() async throws {
        let draft = AdMissionOfferDraft(
            offer: "Newsletter",
            audience: "Indie founders",
            ticket: "",
            country: "",
            language: "",
            budget: "",
            businessGoal: "validate newsletter",
            landingPageURL: "",
            experienceLevel: "",
            recommendedChannel: ""
        )
        let direction = AdMissionCampaignPlanner.direction(for: draft)
        let planMarkdown = AdMissionCampaignPlanner.planMarkdown(for: draft, direction: direction)

        #expect(direction.recommendedObjective == "Leads")
        #expect(direction.riskLevel == .high)
        #expect(direction.nextStep == "Open the selected ads platform, create a campaign, choose Leads, and stop before Publish.")
        #expect(planMarkdown.contains("## Platform\nMeta Ads"))
        #expect(planMarkdown.contains("Set a small daily budget before publishing. Do not scale before you have signal."))
    }

    @Test func startBuilderCreatesPlanningMissionAndReplacesCampaignPlanArtifact() async throws {
        var mission = AdMission.empty()
        mission.decisions = ["Existing decision"]
        mission.artifacts = [
            SpiderArtifact(kind: .creativePack, title: "Creative Pack", markdown: "Keep this."),
            SpiderArtifact(kind: .campaignPlan, title: "Campaign Plan", markdown: "Old plan."),
        ]

        let draft = AdMissionOfferDraft(
            offer: "  Newsletter  ",
            audience: "  Indie founders  ",
            ticket: "  ",
            country: "  BR  ",
            language: "  Portuguese  ",
            budget: "",
            businessGoal: "  validate newsletter  ",
            landingPageURL: "",
            experienceLevel: "  beginner  ",
            recommendedChannel: "   "
        )

        let updatedMission = AdMissionStartBuilder.applying(draft, to: mission)
        let campaignPlanArtifacts = updatedMission.artifacts.filter { $0.kind == .campaignPlan && $0.title == "Campaign Plan" }

        #expect(updatedMission.status == .planning)
        #expect(updatedMission.offer == "Newsletter")
        #expect(updatedMission.targetAudience == "Indie founders")
        #expect(updatedMission.country == "BR")
        #expect(updatedMission.language == "Portuguese")
        #expect(updatedMission.businessObjective == "validate newsletter")
        #expect(updatedMission.experienceLevel == "beginner")
        #expect(updatedMission.recommendedChannel == "Meta Ads")
        #expect(updatedMission.campaignDirection?.recommendedObjective == "Leads")
        #expect(updatedMission.reviewSchedule == SpiderProductFeatures.mvpLockedReviewSchedule)
        #expect(updatedMission.decisions == [
            "Existing decision",
            "Campaign direction created: Leads. Avoid Traffic for this mission.",
        ])
        #expect(updatedMission.artifacts.contains { $0.kind == .creativePack && $0.title == "Creative Pack" })
        #expect(campaignPlanArtifacts.count == 1)
        #expect(campaignPlanArtifacts.first?.markdown == updatedMission.campaignPlan)
        #expect(updatedMission.campaignPlan.contains("## Platform\nMeta Ads"))
        #expect(updatedMission.campaignPlan.contains("stop before Publish"))
    }

    @Test func artifactApplierSanitizesAndReplacesMatchingArtifacts() async throws {
        var mission = AdMission.empty()
        mission.artifacts = [
            SpiderArtifact(kind: .creativePack, title: "Creative Pack", markdown: "Keep this."),
            SpiderArtifact(kind: .campaignPlan, title: "Campaign Plan", markdown: "Old plan."),
        ]

        let updatedMission = try #require(AdMissionArtifactApplier.applying(
            SpiderArtifact(kind: .campaignPlan, title: "  Campaign Plan  ", markdown: "  New plan.  "),
            to: mission
        ))

        #expect(updatedMission.artifacts.count == 2)
        #expect(updatedMission.artifacts.contains {
            $0.kind == .creativePack && $0.title == "Creative Pack" && $0.markdown == "Keep this."
        })
        #expect(updatedMission.artifacts.contains {
            $0.kind == .campaignPlan && $0.title == "Campaign Plan" && $0.markdown == "New plan."
        })
        #expect(updatedMission.artifacts.filter { $0.kind == .campaignPlan && $0.title == "Campaign Plan" }.count == 1)
    }

    @Test func artifactApplierRejectsInvalidArtifactsWithoutChangingMission() async throws {
        var mission = AdMission.empty()
        mission.artifacts = [
            SpiderArtifact(kind: .campaignPlan, title: "Campaign Plan", markdown: "Keep this."),
        ]

        let updatedMission = AdMissionArtifactApplier.applying(
            SpiderArtifact(kind: .campaignPlan, title: "   ", markdown: "New plan."),
            to: mission
        )

        #expect(updatedMission == nil)
        #expect(mission.artifacts == [
            SpiderArtifact(kind: .campaignPlan, title: "Campaign Plan", markdown: "Keep this."),
        ])
    }

    @Test func localPersistenceSavesOnlyChangedMissions() async throws {
        let mission = AdMission.empty()
        var savedMissions: [AdMission] = []

        let unchangedOutcome = AdMissionLocalPersistence.saveIfChanged(
            mission,
            currentMission: mission,
            saveStore: { savedMissions.append($0) }
        )

        var updatedMission = mission
        updatedMission.offer = "Newsletter"
        let savedOutcome = AdMissionLocalPersistence.saveIfChanged(
            updatedMission,
            currentMission: mission,
            saveStore: { savedMissions.append($0) }
        )

        #expect(unchangedOutcome == .unchanged)
        #expect(savedOutcome == .saved(updatedMission))
        #expect(savedMissions == [updatedMission])
    }

    @Test func localPersistenceRejectsInvalidArtifactsBeforeSaving() async throws {
        let mission = AdMission.empty()
        var didAttemptSave = false

        let outcome = AdMissionLocalPersistence.persistArtifact(
            SpiderArtifact(kind: .campaignPlan, title: "   ", markdown: "New plan."),
            to: mission,
            saveStore: { _ in didAttemptSave = true }
        )

        #expect(outcome == .rejectedInvalidArtifact)
        #expect(didAttemptSave == false)
    }

    @Test func localPersistenceReportsSaveAndResetFailuresWithoutThrowing() async throws {
        let mission = AdMission.empty()
        var updatedMission = mission
        updatedMission.offer = "Newsletter"

        let saveOutcome = AdMissionLocalPersistence.saveIfChanged(
            updatedMission,
            currentMission: mission,
            saveStore: { _ in throw AdMissionTestSaveError.failed }
        )
        let resetOutcome = AdMissionLocalPersistence.reset(
            resetStore: { throw AdMissionTestSaveError.failed }
        )

        #expect(saveOutcome == .failed)
        #expect(resetOutcome == .failed)
    }

    @Test func lifecyclePolicyKeepsGuidedSetupAndManualPublishBoundaries() async throws {
        var mission = AdMission.empty()
        mission.decisions = [
            "Existing decision",
            "Guided setup started for Meta Ads. \(SpiderProductFeatures.mvpLockedReviewSchedule)",
        ]

        let guidedMission = AdMissionLifecyclePolicy.guidedSetupStarted(
            mission,
            platformDisplayName: "Meta Ads"
        )
        let preflightMission = AdMissionLifecyclePolicy.preflightAuditRequested(guidedMission)
        let publishedMission = AdMissionLifecyclePolicy.manuallyPublished(preflightMission)

        #expect(guidedMission.status == .guidedSetup)
        #expect(guidedMission.decisions == [
            "Existing decision",
            "Guided setup started for Meta Ads. \(SpiderProductFeatures.mvpLockedReviewSchedule)",
        ])
        #expect(preflightMission.status == .preflightNeeded)
        #expect(publishedMission.status == .publishedManually)
        #expect(publishedMission.reviewSchedule == SpiderProductFeatures.postLaunchReviewLockedSchedule)
        #expect(publishedMission.decisions.contains("Marked as manually published. Spider did not publish or spend."))
    }

    @Test func updateApplierMergesSanitizedFieldsWithoutBlankOverwrites() async throws {
        var mission = AdMission.empty()
        mission.status = .planning
        mission.offer = "Existing offer"
        mission.targetAudience = "Existing audience"
        mission.budget = "$20/day"
        mission.decisions = ["Keep this"]

        let update = AdMissionUpdate(
            offer: "  New offer  ",
            targetAudience: "   ",
            ticket: "  VIP  ",
            country: nil,
            language: " English ",
            budget: "",
            businessObjective: "  Validate purchases  ",
            landingPageURL: nil,
            recommendedChannel: " Meta Ads ",
            campaignPlan: "  Plan v2  ",
            decisions: [" Keep this ", "Pick Sales", "pick sales", "  "],
            reviewSchedule: "  72h review  "
        )

        let updatedMission = AdMissionUpdateApplier.applying(update, to: mission)

        #expect(updatedMission.status == .planning)
        #expect(updatedMission.offer == "New offer")
        #expect(updatedMission.targetAudience == "Existing audience")
        #expect(updatedMission.ticket == "VIP")
        #expect(updatedMission.language == "English")
        #expect(updatedMission.budget == "$20/day")
        #expect(updatedMission.businessObjective == "Validate purchases")
        #expect(updatedMission.recommendedChannel == "Meta Ads")
        #expect(updatedMission.campaignPlan == "Plan v2")
        #expect(updatedMission.decisions == ["Keep this", "Pick Sales"])
        #expect(updatedMission.reviewSchedule == "72h review")
    }

    @Test func updateApplierSanitizesDecisionMemoryWithoutDuplicates() async throws {
        var mission = AdMission.empty()
        mission.status = .guidedSetup
        mission.decisions = ["Known"]

        let duplicateMission = AdMissionUpdateApplier.applyingDecisionMemoryUpdate("  Known  ", to: mission)
        let updatedMission = AdMissionUpdateApplier.applyingDecisionMemoryUpdate("  Fresh decision  ", to: duplicateMission)
        let blankMission = AdMissionUpdateApplier.applyingDecisionMemoryUpdate("   ", to: updatedMission)

        #expect(duplicateMission.status == .guidedSetup)
        #expect(duplicateMission.decisions == ["Known"])
        #expect(updatedMission.decisions == ["Known", "Fresh decision"])
        #expect(blankMission == updatedMission)
    }
}
