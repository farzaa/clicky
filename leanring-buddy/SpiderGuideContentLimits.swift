//
//  SpiderGuideContentLimits.swift
//  leanring-buddy
//
//  Shared size limits for guide contracts, local persistence, and Worker
//  payloads.
//

import Foundation

enum SpiderContentLimits {
    static let maxGuideSpokenTextCharacters = 1_200
    static let maxGuideDisplayTextCharacters = 2_400
    static let maxGuideNextStepCharacters = 1_000
    static let maxGuidePointLabelCharacters = 120
    static let maxGuidePointMissionAlignmentCharacters = 180
    static let maxGuidePointScreenNumber = 16
    static let maxGuideScreenIdentifierCharacters = 96
    static let maxGuideScreenEvidenceItems = 5
    static let maxGuideScreenEvidenceCharacters = 160
    static let maxGuideGroundingVisibleConcepts = 12
    static let maxGuideGroundingTargets = 8
    static let maxGuideGroundingUncertainties = 6
    static let maxGuidePollAfterMilliseconds = 30_000
    static let maxGuideScreenshotCount = 4
    static let maxVisionUserTranscriptCharacters = 12_000
    static let maxVisionConversationHistoryTurns = 6
    static let maxVisionHistoryTextCharacters = 4_000
    static let maxVisionProjectTextFieldCharacters = 2_000
    static let maxVisionProjectListItems = 20
    static let maxVisionProjectListItemCharacters = 240
    static let maxVisionProjectArtifactSummaries = 8
    static let maxScreenSignatureCharacters = 512
    static let maxArtifactTitleCharacters = 140
    static let maxArtifactMarkdownCharacters = 120_000
    static let maxArtifactsPerProject = 30
    static let maxProjectTextFieldCharacters = 8_000
    static let maxProjectListItems = 80
    static let maxProjectListItemCharacters = 500
    static let maxProjectFileBytes = 5_000_000
    static let maxAppLanguageCharacters = 64
}

enum SpiderUserPreferenceKey {
    static let appLanguage = "SpiderAppLanguage"
}

enum SpiderUserPreferences {
    static var appLanguage: String {
        let storedLanguage = UserDefaults.standard.string(forKey: SpiderUserPreferenceKey.appLanguage) ?? "English"
        let sanitizedLanguage = storedLanguage.spiderSanitizedSingleLine(
            maxCharacters: SpiderContentLimits.maxAppLanguageCharacters
        )
        return sanitizedLanguage.isEmpty ? "English" : sanitizedLanguage
    }
}
