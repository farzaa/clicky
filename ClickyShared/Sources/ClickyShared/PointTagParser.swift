//
//  PointTagParser.swift
//  ClickyShared
//
//  Parses Claude's `[POINT:x,y:label]` tag from streaming response text.
//  Extracted from the Clicky macOS app's `CompanionManager.swift`.
//
//  iOS uses a single screenshot at a time, so the multi-screen variant
//  `[POINT:x,y:label:screenN]` from the macOS version is not needed —
//  but the regex still tolerates it for forward compatibility with
//  shared system prompts.
//

import CoreGraphics
import Foundation

/// Result of parsing a `[POINT:...]` tag from Claude's response.
public struct PointingParseResult {
    /// The response text with the `[POINT:...]` tag removed — this is what
    /// gets spoken aloud via TTS.
    public let spokenText: String

    /// The parsed pixel coordinate in the screenshot's coordinate space, or
    /// `nil` if Claude said `[POINT:none]` or no tag was found.
    public let coordinate: CGPoint?

    /// Short human-readable label describing the element (e.g. "save button"),
    /// or "none" when Claude explicitly opted not to point.
    public let elementLabel: String?

    /// Which screen the coordinate refers to (1-based) on multi-display setups.
    /// Not used by the iOS app (always nil there) — kept for parity with the
    /// macOS app's shared system prompt.
    public let screenNumber: Int?
}

public enum PointTagParser {
    /// Parses a `[POINT:x,y:label]` (optionally `[POINT:x,y:label:screenN]`)
    /// or `[POINT:none]` tag from the END of Claude's response.
    ///
    /// Returns the spoken text (with the tag stripped) and the optional
    /// coordinate + label + screen number.
    public static func parse(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] OR [POINT:123,456:label] OR [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(
                  in: responseText,
                  range: NSRange(responseText.startIndex..., in: responseText)
              ) else {
            return PointingParseResult(
                spokenText: responseText,
                coordinate: nil,
                elementLabel: nil,
                screenNumber: nil
            )
        }

        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // [POINT:none] case — group 1 (x) won't have matched
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(
                spokenText: spokenText,
                coordinate: nil,
                elementLabel: "none",
                screenNumber: nil
            )
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4,
           let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange])
                .trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5,
           let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }
}
