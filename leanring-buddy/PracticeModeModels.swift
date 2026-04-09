//
//  PracticeModeModels.swift
//  leanring-buddy
//
//  Shared model surface for Practice Mode session state and structured
//  model responses.
//

import CoreGraphics
import Foundation

enum PracticeVoiceIntent: String, CaseIterable {
    case smallHint = "SMALL_HINT"
    case hint = "HINT"
    case answer = "ANSWER"
    case checkProgress = "CHECK_PROGRESS"
    case terminate = "TERMINATE"
    case unknown = "UNKNOWN"

    static func fromModelValue(_ modelValue: String?) -> PracticeVoiceIntent {
        guard let modelValue else { return .unknown }

        let normalizedValue = modelValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch normalizedValue {
        case "SMALL_HINT", "TINY_HINT", "MINOR_HINT":
            return .smallHint
        case "HINT":
            return .hint
        case "ANSWER", "FULL_ANSWER":
            return .answer
        case "CHECK_PROGRESS", "CHECK", "PROGRESS":
            return .checkProgress
        case "TERMINATE", "DONE", "FINISHED", "STOP":
            return .terminate
        default:
            return .unknown
        }
    }
}

enum PracticeProgressState: String, CaseIterable {
    case notStarted = "NOT_STARTED"
    case inProgress = "IN_PROGRESS"
    case blocked = "BLOCKED"
    case completed = "COMPLETED"
    case unknown = "UNKNOWN"

    static func fromModelValue(_ modelValue: String?) -> PracticeProgressState {
        guard let modelValue else { return .unknown }

        let normalizedValue = modelValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        switch normalizedValue {
        case "NOT_STARTED":
            return .notStarted
        case "IN_PROGRESS", "ON_TRACK":
            return .inProgress
        case "BLOCKED", "STUCK", "OFF_TRACK":
            return .blocked
        case "COMPLETED", "DONE":
            return .completed
        default:
            return .unknown
        }
    }
}

enum PracticeSessionState: String {
    case inactive
    case starting
    case active
    case completed
    case terminated
    case failed
}

enum PracticeMonitorStatus: String {
    case idle
    case running
    case paused
}

struct PracticeChallenge: Equatable {
    let title: String
    let goal: String
    let successCriteria: String
    let screenContextSummary: String
}

struct PracticePointingDirective: Equatable {
    let coordinate: CGPoint
    let label: String?
    let screenNumber: Int?
}

struct PracticeChallengeSuggestion: Equatable {
    let isChallengeAvailable: Bool
    let challenge: PracticeChallenge?
    let unsuitableReason: String?
}

struct PracticeEvaluation: Equatable {
    let resolvedIntent: PracticeVoiceIntent
    let progressState: PracticeProgressState
    let feedback: String
    let hint: String
    let pointingDirective: PracticePointingDirective?
    let isComplete: Bool
    let shouldTerminate: Bool
}

struct PracticeSessionContextSnapshot: Equatable {
    let activeChallenge: PracticeChallenge
    let lastResolvedIntent: PracticeVoiceIntent?
    let lastHintText: String?
}
