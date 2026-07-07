import Foundation

/// A single step in a step-by-step visual guidance sequence.
struct GuidanceStep: Equatable {
    let index: Int
    let total: Int
    let instruction: String
    let rawPointCoordinate: CGPoint?
    let elementLabel: String?
    let screenNumber: Int?
}

/// A multi-step guide parsed from Claude's response when the user asks
/// "how do I..." or "show me how to..." questions.
struct StepByStepGuide: Equatable {
    let totalSteps: Int
    let steps: [GuidanceStep]

    var currentStepIndex: Int = 0

    var currentStep: GuidanceStep? {
        guard currentStepIndex >= 0, currentStepIndex < steps.count else { return nil }
        return steps[currentStepIndex]
    }

    var isComplete: Bool {
        currentStepIndex >= totalSteps
    }

    var progress: Double {
        guard totalSteps > 0 else { return 1.0 }
        return Double(currentStepIndex) / Double(totalSteps)
    }
}

/// Set of phrases the user can say to advance to the next step.
enum StepAdvanceCommand: String, CaseIterable {
    case next = "next"
    case goOn = "go on"
    case okay = "okay"
    case ok = "ok"
    case done = "done"
    case `continue` = "continue"
    case ready = "ready"
    case gotIt = "got it"

    static func matches(_ transcript: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allCases.contains { $0.rawValue == trimmed }
    }
}

/// Parsing result for a [POINT:...] tag within a single step.
private struct TagParseResult {
    let spokenText: String
    let coordinate: CGPoint?
    let elementLabel: String?
    let screenNumber: Int?
}

enum StepByStepGuideParser {

    /// Parses a multi-step guide from Claude's response.
    /// Expected format:
    /// ```
    /// [GUIDE:3]
    /// Click the Insert tab [POINT:500,30:insert tab]
    /// ###
    /// Click Chart in the ribbon [POINT:600,60:chart button]
    /// ###
    /// Select your chart type [POINT:700,200:chart type]
    /// [END_GUIDE]
    /// ```
    /// Returns nil if the response doesn't contain a guide.
    static func parse(from responseText: String) -> (guide: StepByStepGuide, spokenText: String)? {
        let pattern = #"\[GUIDE:(\d+)\]\s*(.*?)\[END_GUIDE\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            return nil
        }

        let fullMatchRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<fullMatchRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard match.numberOfRanges >= 3,
              let totalRange = Range(match.range(at: 1), in: responseText),
              let bodyRange = Range(match.range(at: 2), in: responseText),
              let totalSteps = Int(responseText[totalRange]) else {
            return nil
        }

        let body = String(responseText[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)

        let rawSteps = body.components(separatedBy: "###")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !rawSteps.isEmpty else { return nil }

        var parsedSteps: [GuidanceStep] = []

        for (index, rawStep) in rawSteps.enumerated() {
            let tagResult = parsePointingTag(from: rawStep)
            parsedSteps.append(GuidanceStep(
                index: index,
                total: totalSteps,
                instruction: tagResult.spokenText,
                rawPointCoordinate: tagResult.coordinate,
                elementLabel: tagResult.elementLabel,
                screenNumber: tagResult.screenNumber
            ))
        }

        if parsedSteps.count > totalSteps {
            parsedSteps = Array(parsedSteps.prefix(totalSteps))
        }

        guard !parsedSteps.isEmpty else { return nil }

        let guide = StepByStepGuide(
            totalSteps: totalSteps,
            steps: parsedSteps
        )

        return (guide: guide, spokenText: spokenText)
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of a step's text.
    /// Returns the text with the tag removed and the optional coordinate + label + screen number.
    private static func parsePointingTag(from text: String) -> TagParseResult {
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return TagParseResult(spokenText: text, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        let tagRange = Range(match.range, in: text)!
        let spokenText = String(text[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: text),
              let yRange = Range(match.range(at: 2), in: text),
              let x = Double(text[xRange]),
              let y = Double(text[yRange]) else {
            return TagParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: text) {
            elementLabel = String(text[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: text) {
            screenNumber = Int(text[screenRange])
        }

        return TagParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }
}
