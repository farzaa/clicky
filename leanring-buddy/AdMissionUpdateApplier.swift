//
//  AdMissionUpdateApplier.swift
//  leanring-buddy
//
//  Applies sanitized Worker mission updates without giving CompanionManager
//  ownership of Ad Mission merge rules.
//

import Foundation

struct AdMissionUpdateApplier {
    static func applying(_ missionUpdate: AdMissionUpdate, to mission: AdMission) -> AdMission {
        let sanitizedMissionUpdate = missionUpdate.sanitizedForLocalStorage()
        var updatedMission = mission

        if let offer = nonEmpty(sanitizedMissionUpdate.offer) {
            updatedMission.offer = offer
        }
        if let targetAudience = nonEmpty(sanitizedMissionUpdate.targetAudience) {
            updatedMission.targetAudience = targetAudience
        }
        if let ticket = nonEmpty(sanitizedMissionUpdate.ticket) {
            updatedMission.ticket = ticket
        }
        if let country = nonEmpty(sanitizedMissionUpdate.country) {
            updatedMission.country = country
        }
        if let language = nonEmpty(sanitizedMissionUpdate.language) {
            updatedMission.language = language
        }
        if let budget = nonEmpty(sanitizedMissionUpdate.budget) {
            updatedMission.budget = budget
        }
        if let businessObjective = nonEmpty(sanitizedMissionUpdate.businessObjective) {
            updatedMission.businessObjective = businessObjective
        }
        if let landingPageURL = nonEmpty(sanitizedMissionUpdate.landingPageURL) {
            updatedMission.landingPageURL = landingPageURL
        }
        if let recommendedChannel = nonEmpty(sanitizedMissionUpdate.recommendedChannel) {
            updatedMission.recommendedChannel = recommendedChannel
        }
        if let campaignPlan = nonEmpty(sanitizedMissionUpdate.campaignPlan) {
            updatedMission.campaignPlan = campaignPlan
        }
        if let decisions = sanitizedMissionUpdate.decisions {
            updatedMission.decisions = mergedList(updatedMission.decisions, with: decisions)
        }
        if let reviewSchedule = nonEmpty(sanitizedMissionUpdate.reviewSchedule) {
            updatedMission.reviewSchedule = reviewSchedule
        }

        return updatedMission.sanitizedForLocalStorage()
    }

    static func applyingDecisionMemoryUpdate(_ decisionMemoryUpdate: String, to mission: AdMission) -> AdMission {
        let sanitizedDecision = decisionMemoryUpdate.spiderSanitizedSingleLine(
            maxCharacters: SpiderContentLimits.maxProjectListItemCharacters
        )
        guard !sanitizedDecision.isEmpty else { return mission }

        var updatedMission = mission
        updatedMission.decisions = mergedList(updatedMission.decisions, with: [sanitizedDecision])
        return updatedMission.sanitizedForLocalStorage()
    }

    static func mergedList(_ existingValues: [String], with newValues: [String]) -> [String] {
        var mergedValues = existingValues
        var normalizedValues = Set(existingValues.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })

        for newValue in newValues {
            let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else { continue }

            let normalizedValue = trimmedValue.lowercased()
            guard !normalizedValues.contains(normalizedValue) else { continue }

            normalizedValues.insert(normalizedValue)
            mergedValues.append(trimmedValue)
        }

        return mergedValues
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}
