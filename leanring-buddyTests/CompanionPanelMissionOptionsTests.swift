//
//  CompanionPanelMissionOptionsTests.swift
//  leanring-buddyTests
//
//  Keeps Ad Mission panel option catalogs stable while the panel view is split.
//

import Testing
@testable import Spider

struct CompanionPanelMissionOptionsTests {
    @Test func defaultsKeepExistingWizardFallbacks() {
        #expect(CompanionPanelMissionOptions.defaultMarket == "United States")
        #expect(CompanionPanelMissionOptions.defaultAudienceLanguage == "English")
        #expect(CompanionPanelMissionOptions.defaultAdPlatform == "Meta Ads")
        #expect(CompanionPanelMissionOptions.defaultExperienceLevel == "Beginner")
        #expect(CompanionPanelMissionOptions.defaultTicketAmount == "97")
        #expect(CompanionPanelMissionOptions.defaultTotalTestLimit == "50")
        #expect(CompanionPanelMissionOptions.defaultDailyGuardrail == "10")
        #expect(CompanionPanelMissionOptions.defaultTestLength == "5 days")
        #expect(CompanionPanelMissionOptions.defaultBusinessGoal == "Sell a product")
    }

    @Test func campaignGoalOptionsKeepExistingOrderAndCopyKeys() {
        #expect(CompanionPanelMissionOptions.campaignGoalOptions.map(\.title) == [
            "Sell a product",
            "Get leads",
            "Book calls",
            "Grow a newsletter",
            "Validate an offer",
        ])
        #expect(CompanionPanelMissionOptions.campaignGoalOptions.first?.subtitle == "Drive purchases or paid signups.")
    }

    @Test func marketPlatformAndLanguageOptionsKeepExistingValues() {
        #expect(CompanionPanelMissionOptions.marketOptions.first == "United States")
        #expect(CompanionPanelMissionOptions.marketOptions.contains("Brazil"))
        #expect(CompanionPanelMissionOptions.marketOptions.last == "Colombia")
        #expect(CompanionPanelMissionOptions.adPlatformMenuOptions == [
            "Meta Ads",
            "Google Ads",
            "TikTok Ads",
            "X/Twitter Ads",
            "LinkedIn Ads",
        ])
        #expect(CompanionPanelMissionOptions.audienceLanguageOptions.contains("Mandarin Chinese"))
    }

    @Test func campaignGoalMappingKeepsExistingFallbackRules() {
        #expect(CompanionPanelMissionOptions.campaignGoalFromMission("lead capture") == "Get leads")
        #expect(CompanionPanelMissionOptions.campaignGoalFromMission("book calls") == "Book calls")
        #expect(CompanionPanelMissionOptions.campaignGoalFromMission("newsletter growth") == "Grow a newsletter")
        #expect(CompanionPanelMissionOptions.campaignGoalFromMission("validate an offer") == "Validate an offer")
        #expect(CompanionPanelMissionOptions.campaignGoalFromMission("purchase") == "Sell a product")
    }
}
