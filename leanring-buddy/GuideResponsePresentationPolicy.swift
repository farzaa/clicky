//
//  GuideResponsePresentationPolicy.swift
//  leanring-buddy
//
//  Pure presentation decisions for spoken and status-bubble guide responses.
//

import Foundation

enum GuideResponsePresentationPolicy {
    static func resolvedScreenState(for guideResponse: SpiderGuideResponse) -> SpiderGuideScreenState {
        if let screenState = guideResponse.screenState {
            return screenState
        }
        if isLoading(guideResponse) {
            return .loading
        }
        if guideResponse.contextKind == .unclear || guideResponse.contextKind == .unknownPlatform {
            return .unknown
        }
        if guideResponse.requiresManualConfirmation {
            return .blocked
        }
        return .recognized
    }

    static func shouldSpeak(
        _ guideResponse: SpiderGuideResponse,
        resolvedScreenState: SpiderGuideScreenState,
        isAutomaticScreenRefresh: Bool,
        screenChanged: Bool
    ) -> Bool {
        guard isAutomaticScreenRefresh else { return true }

        if resolvedScreenState == .loading {
            return false
        }
        if !screenChanged {
            return false
        }

        return !isLoading(guideResponse)
    }

    static func shouldShowStatusBubble(
        _ guideResponse: SpiderGuideResponse,
        resolvedScreenState: SpiderGuideScreenState,
        isAutomaticScreenRefresh: Bool,
        screenChanged: Bool,
        suppressRepeatedBubble: Bool
    ) -> Bool {
        if resolvedScreenState == .loading || isLoading(guideResponse) {
            return false
        }

        guard isAutomaticScreenRefresh else { return true }
        if suppressRepeatedBubble {
            return false
        }
        return resolvedScreenState == .unknown || resolvedScreenState == .blocked
    }

    static func isLoading(_ guideResponse: SpiderGuideResponse) -> Bool {
        if guideResponse.screenState == .loading {
            return true
        }
        if guideResponse.screenState != nil {
            return false
        }
        let responseSummary = "\(guideResponse.displayText) \(guideResponse.spokenText) \(guideResponse.nextStep)"
            .lowercased()
        return responseSummary.contains("loading")
            || responseSummary.contains("carregando")
            || responseSummary.contains("cargando")
    }
}
