//
//  CompanionPanelAdMissionPresentationPolicy.swift
//  leanring-buddy
//
//  Presentation-only Ad Mission formatting used by the menu bar panel.
//

struct CompanionPanelAdMissionSummaryRow: Equatable {
    let labelKey: String
    let value: String
}

enum CompanionPanelAdMissionPresentationPolicy {
    static func artifactLabelKey(for kind: SpiderArtifact.Kind) -> String {
        switch kind {
        case .campaignPlan:
            return "Campaign plan"
        case .creativePack:
            return "Creative pack"
        case .preflightAudit:
            return "Preflight audit"
        case .optimizationDecision:
            return "Optimization decision"
        case .trackingChecklist:
            return "Tracking checklist"
        }
    }

    static func summaryRows(for mission: AdMission) -> [CompanionPanelAdMissionSummaryRow] {
        [
            CompanionPanelAdMissionSummaryRow(labelKey: "Offer", value: mission.offer),
            CompanionPanelAdMissionSummaryRow(labelKey: "Audience", value: mission.targetAudience),
            CompanionPanelAdMissionSummaryRow(labelKey: "Goal", value: mission.businessObjective),
            CompanionPanelAdMissionSummaryRow(labelKey: "Budget", value: mission.budget),
        ].filter { !$0.value.isEmpty }
    }

    static func markdownSnapshot(for mission: AdMission) -> String {
        var lines: [String] = ["# Spider Ad Mission Snapshot", ""]

        if let status = mission.status {
            lines.append("## Status")
            lines.append(status.displayTitle)
            lines.append("")
        }
        if !mission.offer.isEmpty {
            lines.append("## Offer")
            lines.append(mission.offer)
            lines.append("")
        }
        if !mission.targetAudience.isEmpty {
            lines.append("## Audience")
            lines.append(mission.targetAudience)
            lines.append("")
        }
        if !mission.ticket.isEmpty {
            lines.append("## Ticket")
            lines.append(mission.ticket)
            lines.append("")
        }
        if !mission.country.isEmpty || !mission.language.isEmpty {
            lines.append("## Market")
            lines.append([mission.country, mission.language].filter { !$0.isEmpty }.joined(separator: " / "))
            lines.append("")
        }
        if !mission.budget.isEmpty {
            lines.append("## Budget")
            lines.append(mission.budget)
            lines.append("")
        }
        if !mission.businessObjective.isEmpty {
            lines.append("## Business Objective")
            lines.append(mission.businessObjective)
            lines.append("")
        }
        if !mission.landingPageURL.isEmpty {
            lines.append("## Landing Page")
            lines.append(mission.landingPageURL)
            lines.append("")
        }
        if let experienceLevel = mission.experienceLevel, !experienceLevel.isEmpty {
            lines.append("## Experience Level")
            lines.append(experienceLevel)
            lines.append("")
        }
        if !mission.recommendedChannel.isEmpty {
            lines.append("## Recommended Channel")
            lines.append(mission.recommendedChannel)
            lines.append("")
        }
        if let direction = mission.campaignDirection {
            lines.append("## Campaign Direction")
            lines.append("Objective: \(direction.recommendedObjective)")
            lines.append("Why: \(direction.whyThisObjective)")
            lines.append("Do not choose: \(direction.whatNotToChoose)")
            lines.append("Event: \(direction.conversionEventSuggestion)")
            lines.append("Next step: \(direction.nextStep)")
            lines.append("")
        }
        if !mission.campaignPlan.isEmpty {
            lines.append("## Campaign Plan")
            lines.append(mission.campaignPlan)
            lines.append("")
        }
        if !mission.reviewSchedule.isEmpty {
            lines.append("## Review Schedule")
            lines.append(mission.reviewSchedule)
            lines.append("")
        }
        if !mission.decisions.isEmpty {
            lines.append("## Decisions")
            lines.append(contentsOf: mission.decisions.map { "- \($0)" })
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
