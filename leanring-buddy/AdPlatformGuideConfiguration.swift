//
//  AdPlatformGuideConfiguration.swift
//  leanring-buddy
//
//  Platform routing metadata for guided setup.
//

import Foundation

struct AdPlatformGuideConfiguration: Equatable {
    let displayName: String
    let launchURLString: String
    let platformContext: SpiderPlatformContext?

    var platformId: SpiderAdPlatformID {
        platformContext?.candidatePlatformId ?? .unknown
    }

    static func resolve(recommendedChannel: String) -> AdPlatformGuideConfiguration {
        let sanitizedChannel = recommendedChannel.spiderSanitizedSingleLine(maxCharacters: 128)
        let displayName = sanitizedChannel.isEmpty ? "Meta Ads" : sanitizedChannel
        let normalizedDisplayName = displayName.lowercased()
        let launchURLString = launchURLStringsByNormalizedDisplayName[normalizedDisplayName]
            ?? launchURLStringsByNormalizedDisplayName["meta ads"]
            ?? "https://adsmanager.facebook.com/adsmanager/manage/campaigns"
        let platformContext: SpiderPlatformContext? = sanitizedChannel.localizedCaseInsensitiveContains("meta")
            ? .metaAds()
            : nil

        return AdPlatformGuideConfiguration(
            displayName: displayName,
            launchURLString: launchURLString,
            platformContext: platformContext
        )
    }

    static func resolve(adMission: AdMission) -> AdPlatformGuideConfiguration {
        resolve(recommendedChannel: adMission.recommendedChannel)
    }

    private static let launchURLStringsByNormalizedDisplayName: [String: String] = [
        "meta ads": "https://adsmanager.facebook.com/adsmanager/manage/campaigns",
        "google ads": "https://ads.google.com/",
        "tiktok ads": "https://ads.tiktok.com/",
        "x ads": "https://ads.twitter.com/",
        "twitter ads": "https://ads.twitter.com/",
        "x/twitter ads": "https://ads.twitter.com/",
        "linkedin ads": "https://www.linkedin.com/campaignmanager/",
    ]
}
