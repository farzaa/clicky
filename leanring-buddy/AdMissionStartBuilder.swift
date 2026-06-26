//
//  AdMissionStartBuilder.swift
//  leanring-buddy
//
//  Builds the local Ad Mission state created from the offer draft.
//

import Foundation

enum AdMissionStartBuilder {
    static func applying(_ draft: AdMissionOfferDraft, to mission: AdMission) -> AdMission {
        let sanitizedDraft = sanitizedOfferDraft(draft)
        let direction = AdMissionCampaignPlanner.direction(for: sanitizedDraft).sanitizedForLocalStorage()
        let planMarkdown = AdMissionCampaignPlanner.planMarkdown(for: sanitizedDraft, direction: direction)
        let planArtifact = SpiderArtifact(
            kind: .campaignPlan,
            title: "Campaign Plan",
            markdown: planMarkdown
        )

        var updatedMission = mission
        updatedMission.status = .planning
        updatedMission.offer = sanitizedDraft.offer
        updatedMission.targetAudience = sanitizedDraft.audience
        updatedMission.ticket = sanitizedDraft.ticket
        updatedMission.country = sanitizedDraft.country
        updatedMission.language = sanitizedDraft.language
        updatedMission.budget = sanitizedDraft.budget
        updatedMission.businessObjective = sanitizedDraft.businessGoal
        updatedMission.landingPageURL = sanitizedDraft.landingPageURL
        updatedMission.experienceLevel = sanitizedDraft.experienceLevel
        updatedMission.recommendedChannel = sanitizedDraft.recommendedChannel.isEmpty ? "Meta Ads" : sanitizedDraft.recommendedChannel
        updatedMission.campaignDirection = direction
        updatedMission.campaignPlan = planMarkdown
        updatedMission.reviewSchedule = SpiderProductFeatures.mvpLockedReviewSchedule
        updatedMission.decisions = AdMissionUpdateApplier.mergedList(updatedMission.decisions, with: [
            "Campaign direction created: \(direction.recommendedObjective). Avoid \(direction.whatNotToChoose) for this mission.",
        ])

        if let sanitizedArtifact = planArtifact.sanitizedForLocalStorage() {
            updatedMission.artifacts.removeAll { $0.kind == .campaignPlan && $0.title == sanitizedArtifact.title }
            updatedMission.artifacts.append(sanitizedArtifact)
        }

        return updatedMission.sanitizedForLocalStorage()
    }

    static func sanitizedOfferDraft(_ draft: AdMissionOfferDraft) -> AdMissionOfferDraft {
        AdMissionOfferDraft(
            offer: draft.offer.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters),
            audience: draft.audience.spiderSanitizedMultiline(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters),
            ticket: draft.ticket.spiderSanitizedSingleLine(maxCharacters: SpiderContentLimits.maxProjectListItemCharacters),
            country: draft.country.spiderSanitizedSingleLine(maxCharacters: SpiderContentLimits.maxProjectListItemCharacters),
            language: draft.language.spiderSanitizedSingleLine(maxCharacters: SpiderContentLimits.maxProjectListItemCharacters),
            budget: draft.budget.spiderSanitizedSingleLine(maxCharacters: SpiderContentLimits.maxProjectListItemCharacters),
            businessGoal: draft.businessGoal.spiderSanitizedSingleLine(maxCharacters: SpiderContentLimits.maxProjectListItemCharacters),
            landingPageURL: draft.landingPageURL.spiderSanitizedSingleLine(maxCharacters: SpiderContentLimits.maxProjectTextFieldCharacters),
            experienceLevel: draft.experienceLevel.spiderSanitizedSingleLine(maxCharacters: SpiderContentLimits.maxProjectListItemCharacters),
            recommendedChannel: draft.recommendedChannel.spiderSanitizedSingleLine(maxCharacters: SpiderContentLimits.maxProjectListItemCharacters)
        )
    }
}
