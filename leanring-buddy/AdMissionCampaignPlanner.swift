//
//  AdMissionCampaignPlanner.swift
//  leanring-buddy
//
//  Pure campaign planning rules for Ad Mission drafts.
//

import Foundation

enum AdMissionCampaignPlanner {
    static func direction(for draft: AdMissionOfferDraft) -> CampaignDirection {
        let normalizedGoal = draft.businessGoal.lowercased()
        let hasLanding = !draft.landingPageURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasBudget = !draft.budget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let platformName = draft.recommendedChannel.isEmpty ? "the selected ads platform" : draft.recommendedChannel

        if normalizedGoal.contains("sales")
            || normalizedGoal.contains("sell")
            || normalizedGoal.contains("product")
            || normalizedGoal.contains("purchase") {
            return CampaignDirection(
                recommendedObjective: "Sales",
                whyThisObjective: "Your goal is purchase intent, not cheap visits.",
                whatNotToChoose: "Traffic",
                conversionEventSuggestion: "Purchase, if available. If not, fix tracking before publishing.",
                audienceStartingPoint: "Start broad. Let the creative qualify the right buyer before splitting into too many ad sets.",
                creativeAngle: "Pain-aware educational hook that makes the buying problem obvious.",
                landingOrTrackingWarning: hasLanding ? "Check that the landing headline matches the ad promise before publishing." : "Add or review the landing page before publishing.",
                riskLevel: hasBudget && hasLanding ? .medium : .high,
                confidence: hasBudget ? .high : .medium,
                nextStep: "Open \(platformName), create a campaign, choose Sales, and stop before Publish."
            )
        }

        if normalizedGoal.contains("lead") || normalizedGoal.contains("book") || normalizedGoal.contains("newsletter") || normalizedGoal.contains("validate") {
            return CampaignDirection(
                recommendedObjective: "Leads",
                whyThisObjective: "Your first useful conversion is a qualified contact, not a raw visit.",
                whatNotToChoose: "Traffic",
                conversionEventSuggestion: "Lead, CompleteRegistration, or the closest available lead event.",
                audienceStartingPoint: "Start with a broad audience and qualify with offer-specific creative.",
                creativeAngle: "Problem and promise hook with a clear reason to leave contact details.",
                landingOrTrackingWarning: hasLanding ? "Make sure the form or booking CTA matches the ad promise." : "Add a form, booking page, or capture page before publishing.",
                riskLevel: hasBudget && hasLanding ? .medium : .high,
                confidence: .medium,
                nextStep: "Open \(platformName), create a campaign, choose Leads, and stop before Publish."
            )
        }

        return CampaignDirection(
            recommendedObjective: "Sales",
            whyThisObjective: "The offer needs a concrete business outcome before platform settings matter.",
            whatNotToChoose: "Traffic",
            conversionEventSuggestion: "Choose Purchase for direct sales or Lead for sales-assisted offers.",
            audienceStartingPoint: "Start broad until the offer and creative prove who responds.",
            creativeAngle: "Mistake-aware hook that explains why the offer matters now.",
            landingOrTrackingWarning: "Clarify the goal and tracking event before publishing.",
            riskLevel: .high,
            confidence: .low,
            nextStep: "Tighten the offer goal, then open \(platformName) for guided setup."
        )
    }

    static func planMarkdown(for draft: AdMissionOfferDraft, direction: CampaignDirection) -> String {
        [
            "# Campaign Plan",
            "",
            "## Platform",
            draft.recommendedChannel.isEmpty ? "Meta Ads" : draft.recommendedChannel,
            "",
            "## Objective",
            direction.recommendedObjective,
            "",
            "## Why not alternatives",
            "Avoid \(direction.whatNotToChoose) for this mission because \(direction.whyThisObjective.lowercased())",
            "",
            "## Structure",
            "1 campaign\n1 ad set\n3 creative variations",
            "",
            "## Budget boundary",
            draft.budget.isEmpty ? "Set a small daily budget before publishing. Do not scale before you have signal." : "Keep the campaign inside \(draft.budget). Do not increase budget before you have signal.",
            "",
            "## Audience starting point",
            direction.audienceStartingPoint,
            "",
            "## Creative tests",
            "- Problem hook\n- Mistake hook\n- Before/after process hook",
            "",
            "## Tracking checklist",
            "- Platform tracking tag or pixel installed\n- \(direction.conversionEventSuggestion)\n- Landing page matches ad promise\n- UTM added",
            "",
            "## Landing page warnings",
            direction.landingOrTrackingWarning,
            "",
            "## Do not touch yet",
            "- Budget scaling\n- Too many audiences\n- Advanced retargeting",
            "",
            "## Next step",
            direction.nextStep,
        ].joined(separator: "\n")
    }
}
