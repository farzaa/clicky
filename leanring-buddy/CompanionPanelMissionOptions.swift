//
//  CompanionPanelMissionOptions.swift
//  leanring-buddy
//
//  Static option catalogs used by the Ad Mission panel wizard.
//

struct CompanionPanelCampaignGoalOption: Identifiable {
    var id: String { title }
    let title: String
    let subtitle: String
}

struct CompanionPanelAdPlatformOption: Identifiable, Equatable {
    var id: String { displayName }
    let displayName: String
}

enum CompanionPanelMissionOptions {
    static let defaultMarket = "United States"
    static let defaultAudienceLanguage = "English"
    static let defaultAdPlatform = "Meta Ads"
    static let defaultExperienceLevel = "Beginner"
    static let defaultTicketAmount = "97"
    static let defaultTotalTestLimit = "50"
    static let defaultDailyGuardrail = "10"
    static let defaultTestLength = "5 days"
    static let defaultBusinessGoal = "Sell a product"

    static let campaignGoalOptions: [CompanionPanelCampaignGoalOption] = [
        CompanionPanelCampaignGoalOption(title: "Sell a product", subtitle: "Drive purchases or paid signups."),
        CompanionPanelCampaignGoalOption(title: "Get leads", subtitle: "Collect emails, forms, or contacts."),
        CompanionPanelCampaignGoalOption(title: "Book calls", subtitle: "Get people to schedule a call."),
        CompanionPanelCampaignGoalOption(title: "Grow a newsletter", subtitle: "Send people to subscribe."),
        CompanionPanelCampaignGoalOption(title: "Validate an offer", subtitle: "Test demand before building more."),
    ]

    static let experienceLevelOptions = ["Beginner", "Some experience", "Advanced"]

    static let marketOptions = [
        "United States",
        "Canada",
        "United Kingdom",
        "Brazil",
        "Mexico",
        "Germany",
        "France",
        "Spain",
        "Italy",
        "Netherlands",
        "Switzerland",
        "Sweden",
        "Portugal",
        "Australia",
        "New Zealand",
        "India",
        "Singapore",
        "United Arab Emirates",
        "Saudi Arabia",
        "Japan",
        "South Korea",
        "China",
        "Indonesia",
        "Philippines",
        "South Africa",
        "Argentina",
        "Chile",
        "Colombia",
    ]

    static let adPlatformOptions: [CompanionPanelAdPlatformOption] = [
        CompanionPanelAdPlatformOption(displayName: "Meta Ads"),
        CompanionPanelAdPlatformOption(displayName: "Google Ads"),
        CompanionPanelAdPlatformOption(displayName: "TikTok Ads"),
        CompanionPanelAdPlatformOption(displayName: "X/Twitter Ads"),
        CompanionPanelAdPlatformOption(displayName: "LinkedIn Ads"),
    ]

    static var adPlatformMenuOptions: [String] {
        adPlatformOptions.map(\.displayName)
    }

    static let audienceLanguageOptions = [
        "English",
        "Portuguese",
        "Spanish",
        "French",
        "German",
        "Italian",
        "Dutch",
        "Swedish",
        "Arabic",
        "Hindi",
        "Japanese",
        "Korean",
        "Mandarin Chinese",
        "Indonesian",
    ]

    static func campaignGoalFromMission(_ missionGoal: String) -> String {
        let normalizedGoal = missionGoal.lowercased()
        if normalizedGoal.contains("lead") {
            return "Get leads"
        }
        if normalizedGoal.contains("book") {
            return "Book calls"
        }
        if normalizedGoal.contains("newsletter") {
            return "Grow a newsletter"
        }
        if normalizedGoal.contains("validate") {
            return "Validate an offer"
        }
        return defaultBusinessGoal
    }
}
