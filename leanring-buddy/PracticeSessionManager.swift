//
//  PracticeSessionManager.swift
//  leanring-buddy
//
//  Owns Practice Mode session bookkeeping plus safe parsing for strict
//  structured model responses.
//

import CoreGraphics
import Foundation

final class PracticeSessionManager {
    private enum ChallengeSuggestionField: String, CaseIterable {
        case challengeAvailable = "CHALLENGE_AVAILABLE"
        case challengeTitle = "CHALLENGE_TITLE"
        case challengeGoal = "CHALLENGE_GOAL"
        case challengeSuccessCriteria = "CHALLENGE_SUCCESS_CRITERIA"
        case challengeContext = "CHALLENGE_CONTEXT"
        case unsuitableReason = "UNSUITABLE_REASON"
    }

    private enum PracticeEvaluationField: String, CaseIterable {
        case intent = "INTENT"
        case state = "STATE"
        case feedback = "FEEDBACK"
        case hint = "HINT"
        case point = "POINT"
        case complete = "COMPLETE"
        case terminate = "TERMINATE"
    }

    private(set) var activeChallenge: PracticeChallenge?
    private(set) var practiceSessionState: PracticeSessionState = .inactive
    private(set) var practiceMonitorStatus: PracticeMonitorStatus = .idle
    private(set) var lastResolvedIntent: PracticeVoiceIntent?
    private(set) var lastHintText: String?
    private(set) var lastEvaluation: PracticeEvaluation?

    func beginSession(with challenge: PracticeChallenge) {
        activeChallenge = challenge
        practiceSessionState = .active
        practiceMonitorStatus = .idle
        lastResolvedIntent = nil
        lastHintText = nil
        lastEvaluation = nil
    }

    func markSessionStarting() {
        practiceSessionState = .starting
    }

    func markMonitorStatus(_ practiceMonitorStatus: PracticeMonitorStatus) {
        self.practiceMonitorStatus = practiceMonitorStatus
    }

    func applyEvaluation(_ practiceEvaluation: PracticeEvaluation) {
        lastEvaluation = practiceEvaluation
        lastResolvedIntent = practiceEvaluation.resolvedIntent

        let trimmedHintText = practiceEvaluation.hint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHintText.isEmpty {
            lastHintText = trimmedHintText
        }

        if practiceEvaluation.shouldTerminate {
            practiceSessionState = .terminated
            return
        }

        if practiceEvaluation.isComplete {
            practiceSessionState = .completed
            return
        }

        if activeChallenge != nil {
            practiceSessionState = .active
        }
    }

    func makeSessionContextSnapshot() -> PracticeSessionContextSnapshot? {
        guard let activeChallenge else { return nil }

        return PracticeSessionContextSnapshot(
            activeChallenge: activeChallenge,
            lastResolvedIntent: lastResolvedIntent,
            lastHintText: lastHintText
        )
    }

    func resetSession() {
        activeChallenge = nil
        practiceSessionState = .inactive
        practiceMonitorStatus = .idle
        lastResolvedIntent = nil
        lastHintText = nil
        lastEvaluation = nil
    }

    static func parseChallengeSuggestion(from modelResponse: String) -> PracticeChallengeSuggestion {
        let parsedSections = parseStructuredSections(
            from: modelResponse,
            supportedKeys: Set(ChallengeSuggestionField.allCases.map(\.rawValue))
        )

        let title = parsedSections[ChallengeSuggestionField.challengeTitle.rawValue]?.trimmedNonEmptyValue
        let goal = parsedSections[ChallengeSuggestionField.challengeGoal.rawValue]?.trimmedNonEmptyValue
        let successCriteria = parsedSections[ChallengeSuggestionField.challengeSuccessCriteria.rawValue]?.trimmedNonEmptyValue
        let challengeContext = parsedSections[ChallengeSuggestionField.challengeContext.rawValue]?.trimmedNonEmptyValue
        let unsuitableReason = parsedSections[ChallengeSuggestionField.unsuitableReason.rawValue]?.trimmedNonEmptyValue

        let challengeAvailable = parseBooleanValue(
            parsedSections[ChallengeSuggestionField.challengeAvailable.rawValue]
        ) ?? (title != nil && goal != nil && successCriteria != nil)

        if challengeAvailable,
           let title,
           let goal,
           let successCriteria {
            return PracticeChallengeSuggestion(
                isChallengeAvailable: true,
                challenge: PracticeChallenge(
                    title: title,
                    goal: goal,
                    successCriteria: successCriteria,
                    screenContextSummary: challengeContext ?? goal
                ),
                unsuitableReason: nil
            )
        }

        return PracticeChallengeSuggestion(
            isChallengeAvailable: false,
            challenge: nil,
            unsuitableReason: unsuitableReason ?? "No safe practice challenge was available for the current screen."
        )
    }

    static func parseEvaluation(from modelResponse: String) -> PracticeEvaluation {
        let parsedSections = parseStructuredSections(
            from: modelResponse,
            supportedKeys: Set(PracticeEvaluationField.allCases.map(\.rawValue))
        )

        let resolvedIntent = PracticeVoiceIntent.fromModelValue(
            parsedSections[PracticeEvaluationField.intent.rawValue]
        )
        let progressState = PracticeProgressState.fromModelValue(
            parsedSections[PracticeEvaluationField.state.rawValue]
        )
        let feedback = parsedSections[PracticeEvaluationField.feedback.rawValue]?.trimmedNonEmptyValue
            ?? "I couldn't confidently evaluate the current practice state."
        let hint = parsedSections[PracticeEvaluationField.hint.rawValue]?.trimmedNonEmptyValue ?? ""
        let pointingDirective = parsePointingDirective(
            from: parsedSections[PracticeEvaluationField.point.rawValue]
        )
        let isComplete = parseBooleanValue(
            parsedSections[PracticeEvaluationField.complete.rawValue]
        ) ?? (progressState == .completed)
        let shouldTerminate = parseBooleanValue(
            parsedSections[PracticeEvaluationField.terminate.rawValue]
        ) ?? (resolvedIntent == .terminate)

        return PracticeEvaluation(
            resolvedIntent: resolvedIntent,
            progressState: progressState,
            feedback: feedback,
            hint: hint,
            pointingDirective: pointingDirective,
            isComplete: isComplete,
            shouldTerminate: shouldTerminate
        )
    }

    private static func parseStructuredSections(
        from text: String,
        supportedKeys: Set<String>
    ) -> [String: String] {
        let cleanedText = stripCodeFences(from: text)
        let normalizedLines = cleanedText.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        var parsedSections: [String: [String]] = [:]
        var currentKey: String?

        for line in normalizedLines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            if let colonIndex = trimmedLine.firstIndex(of: ":") {
                let rawKey = String(trimmedLine[..<colonIndex]).uppercased()
                if supportedKeys.contains(rawKey) {
                    currentKey = rawKey
                    let rawValue = String(trimmedLine[trimmedLine.index(after: colonIndex)...])
                        .trimmingCharacters(in: .whitespaces)
                    parsedSections[rawKey] = rawValue.isEmpty ? [] : [rawValue]
                    continue
                }
            }

            guard let currentKey, !trimmedLine.isEmpty else { continue }
            parsedSections[currentKey, default: []].append(trimmedLine)
        }

        return parsedSections.mapValues { sectionLines in
            sectionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func stripCodeFences(from text: String) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedText.hasPrefix("```"), trimmedText.hasSuffix("```") else {
            return trimmedText
        }

        var lines = trimmedText.components(separatedBy: "\n")

        if !lines.isEmpty {
            lines.removeFirst()
        }

        if !lines.isEmpty, lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
            lines.removeLast()
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseBooleanValue(_ rawValue: String?) -> Bool? {
        guard let normalizedValue = rawValue?.trimmedNonEmptyValue?.uppercased() else {
            return nil
        }

        switch normalizedValue {
        case "YES", "TRUE", "1":
            return true
        case "NO", "FALSE", "0":
            return false
        default:
            return nil
        }
    }

    private static func parsePointingDirective(from rawValue: String?) -> PracticePointingDirective? {
        guard let rawValue = rawValue?.trimmedNonEmptyValue else {
            return nil
        }

        if rawValue.uppercased() == "NONE" {
            return nil
        }

        let pointTagPattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let pointTagRegularExpression = try? NSRegularExpression(pattern: pointTagPattern, options: []),
              let match = pointTagRegularExpression.firstMatch(
                in: rawValue,
                range: NSRange(rawValue.startIndex..., in: rawValue)
              ) else {
            return nil
        }

        guard let xRange = Range(match.range(at: 1), in: rawValue),
              let yRange = Range(match.range(at: 2), in: rawValue),
              let xCoordinate = Double(rawValue[xRange]),
              let yCoordinate = Double(rawValue[yRange]) else {
            return nil
        }

        let label: String? = {
            guard let labelRange = Range(match.range(at: 3), in: rawValue) else {
                return nil
            }

            return String(rawValue[labelRange]).trimmingCharacters(in: .whitespaces)
        }()

        let screenNumber: Int? = {
            guard let screenRange = Range(match.range(at: 4), in: rawValue) else {
                return nil
            }

            return Int(rawValue[screenRange])
        }()

        return PracticePointingDirective(
            coordinate: CGPoint(x: xCoordinate, y: yCoordinate),
            label: label,
            screenNumber: screenNumber
        )
    }
}

private extension String {
    var trimmedNonEmptyValue: String? {
        let trimmedValue = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}
