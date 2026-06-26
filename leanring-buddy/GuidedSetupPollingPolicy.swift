//
//  GuidedSetupPollingPolicy.swift
//  leanring-buddy
//
//  Timing policy for automatic guided setup polling.
//

import Foundation

enum GuidedSetupPollingPolicy {
    enum ContinuationDecision: Equatable {
        enum FinishReason: Equatable {
            case maximumAutomaticPollsReached
            case workerStoppedPolling
        }

        case continueAfter(UInt64)
        case finish(FinishReason)
    }

    static let initialPollDelayNanoseconds: UInt64 = 2_000_000_000
    static let preDotVerificationPollDelayNanoseconds: UInt64 = 650_000_000
    static let loadingPollDelayNanoseconds: UInt64 = 2_500_000_000
    static let followUpPollDelayNanoseconds: UInt64 = 4_500_000_000
    static let unknownPollDelayNanoseconds: UInt64 = 5_500_000_000
    static let maximumAutomaticPolls = 18

    static func continuationDecision(
        afterPollIndex pollIndex: Int,
        for guidedSetupSession: GuidedSetupSession,
        screenState: SpiderGuideScreenState,
        shouldContinuePolling: Bool?,
        suggestedPollAfterMs: Int?
    ) -> ContinuationDecision {
        guard pollIndex < maximumAutomaticPolls else {
            return .finish(.maximumAutomaticPollsReached)
        }

        if shouldContinuePolling == false,
           guidedSetupSession.pendingPreDotVerification == nil {
            return .finish(.workerStoppedPolling)
        }

        return .continueAfter(nextPollDelayNanoseconds(
            for: guidedSetupSession,
            screenState: screenState,
            suggestedPollAfterMs: suggestedPollAfterMs
        ))
    }

    static func nextPollDelayNanoseconds(
        for guidedSetupSession: GuidedSetupSession,
        screenState: SpiderGuideScreenState,
        suggestedPollAfterMs: Int?
    ) -> UInt64 {
        if guidedSetupSession.pendingPreDotVerification != nil {
            return preDotVerificationPollDelayNanoseconds
        }

        if let suggestedPollAfterMs,
           suggestedPollAfterMs >= 1_000,
           suggestedPollAfterMs <= SpiderContentLimits.maxGuidePollAfterMilliseconds {
            return UInt64(suggestedPollAfterMs) * 1_000_000
        }

        switch screenState {
        case .loading:
            return guidedSetupSession.consecutiveUnchangedCount >= 2
                ? followUpPollDelayNanoseconds
                : loadingPollDelayNanoseconds
        case .unknown:
            return unknownPollDelayNanoseconds
        case .recognized, .blocked:
            return guidedSetupSession.consecutiveUnchangedCount >= 1
                ? unknownPollDelayNanoseconds
                : followUpPollDelayNanoseconds
        }
    }
}
