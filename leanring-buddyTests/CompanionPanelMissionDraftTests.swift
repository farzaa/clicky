//
//  CompanionPanelMissionDraftTests.swift
//  leanring-buddyTests
//
//  Locks Ad Mission wizard state shaping outside CompanionPanelView.
//

import Foundation
import Testing
@testable import Spider

struct CompanionPanelMissionDraftTests {
    @Test func defaultsExposeExistingWizardFallbacks() {
        let draft = CompanionPanelMissionDraft()

        #expect(draft.marketValue == "United States")
        #expect(draft.audienceLanguageValue == "English")
        #expect(draft.adPlatformValue == "Meta Ads")
        #expect(draft.ticketCurrencyCode == "USD")
        #expect(draft.totalTestLimit == "50")
        #expect(draft.dailyGuardrail == "10")
        #expect(draft.testLength == "5 days")
        #expect(draft.businessGoal == "Sell a product")
        #expect(draft.experienceLevel == "Beginner")
    }

    @Test func audienceDefaultsFillOnlyMissingFields() {
        var draft = CompanionPanelMissionDraft(
            ticketAmount: "120",
            country: "",
            language: "Spanish",
            adPlatform: ""
        )

        draft.applyAudienceDefaultsIfNeeded()

        #expect(draft.ticketAmount == "120")
        #expect(draft.country == "United States")
        #expect(draft.language == "Spanish")
        #expect(draft.adPlatform == "Meta Ads")
    }

    @Test func testLimitDefaultsNormalizeCurrencyPrefixesAndDailyGuardrail() {
        var draft = CompanionPanelMissionDraft(
            ticketCurrencyCode: "USD",
            totalTestLimit: "USD 50",
            dailyGuardrail: "USD 10/day",
            testLength: ""
        )

        draft.applyTestLimitDefaultsIfNeeded()

        #expect(draft.totalTestLimit == "50")
        #expect(draft.dailyGuardrail == "10")
        #expect(draft.testLength == "5 days")
    }

    @Test func prefillUsesStoredMissionAndExistingFallbackRules() {
        var draft = CompanionPanelMissionDraft()
        let mission = adMission(
            offer: "AI course",
            audience: "Freelancers",
            ticket: "EUR 49",
            country: "Germany",
            language: "German",
            businessObjective: "lead capture",
            landingPageURL: "https://example.com",
            experienceLevel: "",
            recommendedChannel: ""
        )

        draft.prefill(from: mission)

        #expect(draft.offer == "AI course")
        #expect(draft.audience == "Freelancers")
        #expect(draft.ticketAmount == "49")
        #expect(draft.ticketCurrencyCode == "EUR")
        #expect(draft.country == "Germany")
        #expect(draft.language == "German")
        #expect(draft.businessGoal == "Get leads")
        #expect(draft.landingPageURL == "https://example.com")
        #expect(draft.experienceLevel == "Beginner")
        #expect(draft.adPlatform == "Meta Ads")
    }

    @Test func prefillPreservesStoredExperienceAndPlatformWhenPresent() {
        var draft = CompanionPanelMissionDraft()
        let mission = adMission(
            offer: "Security SaaS",
            audience: "B2B buyers",
            ticket: "USD 499",
            country: "United States",
            language: "English",
            businessObjective: "book calls",
            landingPageURL: "",
            experienceLevel: "Advanced",
            recommendedChannel: "LinkedIn Ads"
        )

        draft.prefill(from: mission)

        #expect(draft.businessGoal == "Book calls")
        #expect(draft.experienceLevel == "Advanced")
        #expect(draft.adPlatform == "LinkedIn Ads")
    }

    @Test func adMissionOfferDraftBuildsExistingManualBoundaryPayload() {
        var draft = CompanionPanelMissionDraft(
            offer: "Analytics course",
            audience: "Operators",
            ticketAmount: "R$ 97",
            ticketCurrencyCode: "BRL",
            country: "Brazil",
            language: "Portuguese",
            totalTestLimit: "BRL 100",
            dailyGuardrail: "R$20/day",
            testLength: "7 days",
            businessGoal: "Get leads",
            landingPageURL: "https://example.com",
            experienceLevel: "Some experience",
            adPlatform: "Google Ads"
        )

        let offerDraft = draft.adMissionOfferDraft()

        #expect(offerDraft.offer == "Analytics course")
        #expect(offerDraft.audience == "Operators")
        #expect(offerDraft.ticket == "BRL 97")
        #expect(offerDraft.country == "Brazil")
        #expect(offerDraft.language == "Portuguese")
        #expect(offerDraft.budget == "Total test limit: BRL 100 · Daily guardrail: BRL 20/day · Test length: 7 days")
        #expect(offerDraft.businessGoal == "Get leads")
        #expect(offerDraft.landingPageURL == "https://example.com")
        #expect(offerDraft.experienceLevel == "Some experience")
        #expect(offerDraft.recommendedChannel == "Google Ads")
    }

    private func adMission(
        offer: String,
        audience: String,
        ticket: String,
        country: String,
        language: String,
        businessObjective: String,
        landingPageURL: String,
        experienceLevel: String?,
        recommendedChannel: String
    ) -> AdMission {
        AdMission(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            status: .draft,
            offer: offer,
            targetAudience: audience,
            ticket: ticket,
            country: country,
            language: language,
            budget: "",
            businessObjective: businessObjective,
            landingPageURL: landingPageURL,
            experienceLevel: experienceLevel,
            recommendedChannel: recommendedChannel,
            campaignDirection: nil,
            campaignPlan: "",
            decisions: [],
            reviewSchedule: "",
            artifacts: [],
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
