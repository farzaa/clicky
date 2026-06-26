//
//  GuidedSetupScreenIdentityResolver.swift
//  leanring-buddy
//
//  Resolves stable screen/stage identifiers for guided setup session state.
//

import Foundation

struct GuidedSetupScreenIdentity {
    let screenId: String
    let stageId: String
}

enum GuidedSetupScreenIdentityResolver {
    static func currentIdentity(
        from response: SpiderGuideResponse,
        resolvedScreenState: SpiderGuideScreenState
    ) -> GuidedSetupScreenIdentity {
        GuidedSetupScreenIdentity(
            screenId: nonEmpty(response.screenId) ?? fallbackScreenId(for: resolvedScreenState),
            stageId: nonEmpty(response.stageId) ?? fallbackStageId(for: resolvedScreenState)
        )
    }

    static func sanitizedOutcomeIdentity(
        from response: SpiderGuideResponse,
        resolvedScreenState: SpiderGuideScreenState
    ) -> GuidedSetupScreenIdentity {
        GuidedSetupScreenIdentity(
            screenId: response.screenId?.spiderSanitizedSingleLine(
                maxCharacters: SpiderContentLimits.maxGuideScreenIdentifierCharacters
            ) ?? fallbackScreenId(for: resolvedScreenState),
            stageId: response.stageId?.spiderSanitizedSingleLine(
                maxCharacters: SpiderContentLimits.maxGuideScreenIdentifierCharacters
            ) ?? fallbackStageId(for: resolvedScreenState)
        )
    }

    static func fallbackScreenId(for screenState: SpiderGuideScreenState) -> String {
        switch screenState {
        case .loading:
            return "loading_screen"
        case .unknown:
            return "unknown_screen"
        case .recognized:
            return "recognized_screen"
        case .blocked:
            return "blocked_screen"
        }
    }

    static func fallbackStageId(for screenState: SpiderGuideScreenState) -> String {
        switch screenState {
        case .loading:
            return "loading"
        case .unknown:
            return "unknown_stage"
        case .recognized:
            return "recognized_stage"
        case .blocked:
            return "blocked_stage"
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
