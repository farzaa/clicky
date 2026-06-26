//
//  CompanionPanelAdMissionPresentationPolicyTests.swift
//  leanring-buddyTests
//
//  Locks the Ad Mission panel's local presentation formatting outside SwiftUI.
//

import Foundation
import Testing
@testable import Spider

struct CompanionPanelAdMissionPresentationPolicyTests {
    @Test func artifactLabelKeysKeepExistingPanelCopyKeys() {
        #expect(CompanionPanelAdMissionPresentationPolicy.artifactLabelKey(for: .campaignPlan) == "Campaign plan")
        #expect(CompanionPanelAdMissionPresentationPolicy.artifactLabelKey(for: .creativePack) == "Creative pack")
        #expect(CompanionPanelAdMissionPresentationPolicy.artifactLabelKey(for: .preflightAudit) == "Preflight audit")
        #expect(CompanionPanelAdMissionPresentationPolicy.artifactLabelKey(for: .optimizationDecision) == "Optimization decision")
        #expect(CompanionPanelAdMissionPresentationPolicy.artifactLabelKey(for: .trackingChecklist) == "Tracking checklist")
    }

    @Test func summaryRowsKeepExistingOrderAndSkipBlankValues() {
        var mission = AdMission.empty()
        mission.offer = "Course"
        mission.targetAudience = "Founders"
        mission.businessObjective = "Sell a product"
        mission.budget = ""

        let rows = CompanionPanelAdMissionPresentationPolicy.summaryRows(for: mission)
        #expect(rows.map(\.labelKey) == ["Offer", "Audience", "Goal"])
        #expect(rows.map(\.value) == ["Course", "Founders", "Sell a product"])
    }

    @Test func markdownSnapshotKeepsExistingSectionOrderAndManualBoundaryText() {
        var mission = AdMission.empty()
        mission.status = .planning
        mission.offer = "Course"
        mission.targetAudience = "Founders"
        mission.ticket = "$99"
        mission.country = "US"
        mission.language = "English"
        mission.budget = "$50 total"
        mission.businessObjective = "Sell a product"
        mission.landingPageURL = "https://example.com"
        mission.experienceLevel = "Beginner"
        mission.recommendedChannel = "Meta Ads"
        mission.campaignDirection = CampaignDirection(
            recommendedObjective: "Sales",
            whyThisObjective: "Buyer intent is explicit.",
            whatNotToChoose: "Traffic",
            conversionEventSuggestion: "Purchase",
            audienceStartingPoint: "Founders",
            creativeAngle: "Proof-led",
            landingOrTrackingWarning: "Check pixel before publish.",
            riskLevel: .medium,
            confidence: .high,
            nextStep: "Open Meta Ads and stop before Publish."
        )
        mission.campaignPlan = "Plan body"
        mission.reviewSchedule = "Review after 72h"
        mission.decisions = [
            "Keep budget manual",
            "Stop before Publish",
        ]

        #expect(CompanionPanelAdMissionPresentationPolicy.markdownSnapshot(for: mission) == [
            "# Spider Ad Mission Snapshot",
            "",
            "## Status",
            "Planning",
            "",
            "## Offer",
            "Course",
            "",
            "## Audience",
            "Founders",
            "",
            "## Ticket",
            "$99",
            "",
            "## Market",
            "US / English",
            "",
            "## Budget",
            "$50 total",
            "",
            "## Business Objective",
            "Sell a product",
            "",
            "## Landing Page",
            "https://example.com",
            "",
            "## Experience Level",
            "Beginner",
            "",
            "## Recommended Channel",
            "Meta Ads",
            "",
            "## Campaign Direction",
            "Objective: Sales",
            "Why: Buyer intent is explicit.",
            "Do not choose: Traffic",
            "Event: Purchase",
            "Next step: Open Meta Ads and stop before Publish.",
            "",
            "## Campaign Plan",
            "Plan body",
            "",
            "## Review Schedule",
            "Review after 72h",
            "",
            "## Decisions",
            "- Keep budget manual",
            "- Stop before Publish",
            "",
        ].joined(separator: "\n"))
    }
}
