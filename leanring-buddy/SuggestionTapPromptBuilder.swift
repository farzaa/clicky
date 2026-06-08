//
//  SuggestionTapPromptBuilder.swift
//  leanring-buddy
//
//  Hidden system-prompt context when the user taps a discovery suggestion chip.
//

import Foundation

struct SuggestionTapContext: Equatable {
    let suggestion: NicheSuggestion
    let suggestionMode: NicheSuggestionSnapshot.Mode
    let frontmostBundleId: String?
    let frontmostAppDisplayName: String?
    let effectiveNiche: NicheDiscoveryManager.Niche?
    let inferredNiche: NicheDiscoveryManager.Niche?
    let profileIsStable: Bool
    let profileConfidence: Double
    let isUserNicheOverride: Bool
}

enum SuggestionTapPromptBuilder {
    static let e2eAssertionMarker = "suggestion tap context"

    static func systemPromptClause(for context: SuggestionTapContext) -> String {
        var lines: [String] = []
        lines.append("\(e2eAssertionMarker):")
        lines.append(
            "the user tapped a discovery suggestion chip in the menu bar panel — they did not use push-to-talk."
        )
        lines.append("suggestion id: \(context.suggestion.id)")
        lines.append(
            "suggested intent (treat as what they want help with, not a claim about what's visible): \"\(context.suggestion.prompt)\""
        )
        lines.append("suggestion selection mode: \(context.suggestionMode.rawValue)")

        if let bundleId = context.frontmostBundleId {
            let displayName = context.frontmostAppDisplayName ?? bundleId
            lines.append("frontmost app when they tapped: \(displayName) (\(bundleId))")
        } else {
            lines.append("frontmost app when they tapped: unknown")
        }

        appendBackgroundProfileHint(to: &lines, context: context)

        lines.append("")
        lines.append("rules for this turn:")
        lines.append(
            "- look at the screenshot first. if what's visible doesn't match the suggested intent, briefly acknowledge the mismatch and help with what's actually on screen."
        )
        lines.append(
            "- treat the suggested prompt as intent, not proof the screen shows that app or task."
        )
        lines.append(
            "- do not tell the user you inferred their job, niche, or profile, and do not mention that they tapped a suggestion chip."
        )
        lines.append("- still use [POINT:...] when pointing would help with what's actually visible.")

        return lines.joined(separator: "\n")
    }

    private static func appendBackgroundProfileHint(
        to lines: inout [String],
        context: SuggestionTapContext
    ) {
        if context.isUserNicheOverride, let effectiveNiche = context.effectiveNiche {
            lines.append(
                "background profile hint: user manually chose the \(effectiveNiche.displayName.lowercased()) suggestion category."
            )
            return
        }

        if let inferredNiche = context.inferredNiche, context.profileIsStable {
            let confidencePercent = Int((context.profileConfidence * 100).rounded())
            lines.append(
                "background profile hint: inferred \(inferredNiche.displayName.lowercased()) usage from recent apps (confidence ~\(confidencePercent)%)."
            )
            return
        }

        if let effectiveNiche = context.effectiveNiche {
            lines.append(
                "background profile hint: showing \(effectiveNiche.displayName.lowercased())-leaning suggestions."
            )
        }
    }
}
