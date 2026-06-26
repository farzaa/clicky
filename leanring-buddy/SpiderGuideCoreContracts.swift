//
//  SpiderGuideCoreContracts.swift
//  leanring-buddy
//
//  Core guide enums, artifact contracts, and platform context used by the
//  macOS app and Worker payloads.
//

import Foundation

struct SpiderArtifact: Codable, Equatable {
    enum Kind: String, Codable {
        case campaignPlan
        case creativePack
        case preflightAudit
        case optimizationDecision
        case trackingChecklist
    }

    let kind: Kind
    let title: String
    let markdown: String
}

enum SpiderGuideContextKind: String, Codable, Equatable {
    case adsCommandCenter = "ads_command_center"
    case adMission = "ad_mission"
    case offerReadiness = "offer_readiness"
    case channelRecommendation = "channel_recommendation"
    case campaignPlan = "campaign_plan"
    case platformManager = "platform_manager"
    case platformGuidedSetup = "platform_guided_setup"
    case platformPreflightAudit = "platform_preflight_audit"
    case platformReporting = "platform_reporting"
    case unknownPlatform = "unknown_platform"
    case metaAdsManager = "meta_ads_manager"
    case guidedSetup = "guided_setup"
    case creativeReview = "creative_review"
    case preflightAudit = "preflight_audit"
    case performanceReview = "performance_review"
    case unclear
    case other
}

enum SpiderGuideDecision: String, Codable, Equatable {
    case safeToContinue = "safe_to_continue"
    case continueWithWarning = "continue_with_warning"
    case fixBeforePublish = "fix_before_publish"
    case needsMoreSignal = "needs_more_signal"
    case doNotPublish = "do_not_publish"
    case manualConfirmationRequired = "manual_confirmation_required"
}

enum SpiderGuideRiskLevel: String, Codable, Equatable {
    case low
    case medium
    case high
    case critical
}

enum SpiderGuideConfidence: String, Codable, Equatable {
    case low
    case medium
    case high
}

enum SpiderGuideScreenState: String, Codable, Equatable {
    case loading
    case recognized
    case unknown
    case blocked
}

enum SpiderGuideExpectedOutcome: String, Codable, Equatable {
    case stageAdvanced = "stage_advanced"
    case modalOpened = "modal_opened"
    case modalClosed = "modal_closed"
    case dropdownOpened = "dropdown_opened"
    case itemSelected = "item_selected"
    case tileSelected = "tile_selected"
    case fieldFocused = "field_focused"
    case fieldFilled = "field_filled"
    case buttonEnabled = "button_enabled"
    case buttonDisabled = "button_disabled"
    case screenAdvanced = "screen_advanced"
    case wizardAdvanced = "wizard_advanced"
    case stateChanged = "state_changed"
    case warningAppeared = "warning_appeared"
    case warningCleared = "warning_cleared"
    case unknown
}

enum SpiderGuideSourceType: String, Codable, Equatable {
    case officialRule = "official_rule"
    case officialDefinition = "official_definition"
    case officialGuidance = "official_guidance"
    case spiderPlaybook = "spider_playbook"
    case userContext = "user_context"
    case mixed
}

enum SpiderAdPlatformID: String, Codable, Equatable {
    case metaAds = "meta_ads"
    case unknown = "unknown_platform"
}

enum SpiderPlatformContextSource: String, Codable, Equatable {
    case app
    case screen
    case user
    case unknown
}

struct SpiderPlatformContext: Encodable, Equatable {
    let candidatePlatformId: SpiderAdPlatformID
    let source: SpiderPlatformContextSource
    let visibleURLHost: String?

    static func metaAds(
        source: SpiderPlatformContextSource = .app,
        visibleURLHost: String? = "adsmanager.facebook.com"
    ) -> SpiderPlatformContext {
        SpiderPlatformContext(
            candidatePlatformId: .metaAds,
            source: source,
            visibleURLHost: visibleURLHost
        )
    }

    func sanitizedForTransmission() -> SpiderPlatformContext {
        SpiderPlatformContext(
            candidatePlatformId: candidatePlatformId,
            source: source,
            visibleURLHost: visibleURLHost?.spiderSanitizedSingleLine(maxCharacters: 128)
        )
    }
}
