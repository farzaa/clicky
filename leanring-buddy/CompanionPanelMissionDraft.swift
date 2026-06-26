//
//  CompanionPanelMissionDraft.swift
//  leanring-buddy
//
//  Pure Ad Mission wizard draft state. Keeps form defaults and mission payload
//  shaping out of the SwiftUI panel.
//

import Foundation

struct CompanionPanelMissionDraft: Equatable {
    var offer: String = ""
    var audience: String = ""
    var ticketAmount: String = ""
    var ticketCurrencyCode: String = CompanionPanelMissionMoneyPolicy.defaultCurrencyCode
    var country: String = ""
    var language: String = ""
    var totalTestLimit: String = CompanionPanelMissionOptions.defaultTotalTestLimit
    var dailyGuardrail: String = CompanionPanelMissionOptions.defaultDailyGuardrail
    var testLength: String = CompanionPanelMissionOptions.defaultTestLength
    var businessGoal: String = CompanionPanelMissionOptions.defaultBusinessGoal
    var landingPageURL: String = ""
    var experienceLevel: String = CompanionPanelMissionOptions.defaultExperienceLevel
    var adPlatform: String = CompanionPanelMissionOptions.defaultAdPlatform

    var marketValue: String {
        country.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? CompanionPanelMissionOptions.defaultMarket
            : country
    }

    var audienceLanguageValue: String {
        language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? CompanionPanelMissionOptions.defaultAudienceLanguage
            : language
    }

    var adPlatformValue: String {
        let sanitizedPlatform = adPlatform.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedPlatform.isEmpty else {
            return CompanionPanelMissionOptions.defaultAdPlatform
        }
        return sanitizedPlatform
    }

    mutating func prefill(from mission: AdMission) {
        offer = mission.offer
        audience = mission.targetAudience
        applyTicketFromStoredValue(mission.ticket)
        country = mission.country
        language = mission.language
        businessGoal = CompanionPanelMissionOptions.campaignGoalFromMission(mission.businessObjective)
        landingPageURL = mission.landingPageURL
        if let storedExperienceLevel = mission.experienceLevel, !storedExperienceLevel.isEmpty {
            experienceLevel = storedExperienceLevel
        } else {
            experienceLevel = CompanionPanelMissionOptions.defaultExperienceLevel
        }
        if !mission.recommendedChannel.isEmpty {
            adPlatform = mission.recommendedChannel
        } else {
            adPlatform = CompanionPanelMissionOptions.defaultAdPlatform
        }
        applyTestLimitDefaultsIfNeeded()
    }

    mutating func applyAudienceDefaultsIfNeeded() {
        if ticketAmount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ticketAmount = CompanionPanelMissionOptions.defaultTicketAmount
        }
        if country.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            country = CompanionPanelMissionOptions.defaultMarket
        }
        if language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            language = CompanionPanelMissionOptions.defaultAudienceLanguage
        }
        if adPlatform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            adPlatform = CompanionPanelMissionOptions.defaultAdPlatform
        }
    }

    mutating func applyTestLimitDefaultsIfNeeded() {
        let sanitizedTotalLimit = totalTestLimit.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitizedTotalLimit.isEmpty {
            totalTestLimit = CompanionPanelMissionOptions.defaultTotalTestLimit
        } else {
            totalTestLimit = CompanionPanelMissionMoneyPolicy.normalizedTicketAmount(
                sanitizedTotalLimit,
                currencyCode: ticketCurrencyCode
            )
        }

        let sanitizedDailyGuardrail = dailyGuardrail.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitizedDailyGuardrail.isEmpty {
            dailyGuardrail = CompanionPanelMissionOptions.defaultDailyGuardrail
        } else {
            dailyGuardrail = CompanionPanelMissionMoneyPolicy.normalizedDailyGuardrailAmount(
                sanitizedDailyGuardrail,
                currencyCode: ticketCurrencyCode
            )
        }

        if testLength.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            testLength = CompanionPanelMissionOptions.defaultTestLength
        }
    }

    mutating func adMissionOfferDraft() -> AdMissionOfferDraft {
        applyAudienceDefaultsIfNeeded()
        applyTestLimitDefaultsIfNeeded()

        return AdMissionOfferDraft(
            offer: offer,
            audience: audience,
            ticket: ticketValueForMission,
            country: country,
            language: language,
            budget: budgetBoundary,
            businessGoal: businessGoal,
            landingPageURL: landingPageURL,
            experienceLevel: experienceLevel,
            recommendedChannel: adPlatformValue
        )
    }

    private var ticketValueForMission: String {
        CompanionPanelMissionMoneyPolicy.monetaryValueForMission(
            ticketAmount,
            currencyCode: ticketCurrencyCode
        )
    }

    private var dailyGuardrailValueForMission: String {
        let amount = CompanionPanelMissionMoneyPolicy.normalizedDailyGuardrailAmount(
            dailyGuardrail,
            currencyCode: ticketCurrencyCode
        )
        let monetaryValue = CompanionPanelMissionMoneyPolicy.monetaryValueForMission(
            amount,
            currencyCode: ticketCurrencyCode
        )
        guard !monetaryValue.isEmpty else { return "" }
        return "\(monetaryValue)/day"
    }

    private mutating func applyTicketFromStoredValue(_ storedTicket: String) {
        let ticketInputValue = CompanionPanelMissionMoneyPolicy.ticketInput(fromStoredValue: storedTicket)
        ticketAmount = ticketInputValue.amount
        ticketCurrencyCode = ticketInputValue.currencyCode
    }

    private var budgetBoundary: String {
        let totalTestLimitValue = CompanionPanelMissionMoneyPolicy.monetaryValueForMission(
            totalTestLimit,
            currencyCode: ticketCurrencyCode
        )

        return [
            "Total test limit: \(totalTestLimitValue)",
            "Daily guardrail: \(dailyGuardrailValueForMission)",
            "Test length: \(testLength)",
        ].joined(separator: " · ")
    }
}
