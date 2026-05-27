//
//  VaultIntentDetector.swift
//  leanring-buddy
//
//  Detects when the user explicitly asks for vault or internal knowledge context.
//

import Foundation

enum VaultIntentDetector {
    private static let explicitPhrases = [
        "my vault",
        "my notes",
        "my obsidian",
        "internal knowledge",
        "knowledge brain",
        "clicky brain",
        "personal vault",
        "from my vault",
        "in my vault",
        "from my notes",
        "in my notes",
        "what did i write",
        "what do my notes say",
        "what have i written",
        "search my notes",
        "look in my notes",
        "check my notes"
    ]

    private static let excludedPhrases = [
        "take notes",
        "write notes",
        "open notes app"
    ]

    static func shouldRetrievePersonalKnowledge(transcript: String) -> Bool {
        let normalizedTranscript = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalizedTranscript.isEmpty else { return false }

        for excludedPhrase in excludedPhrases where normalizedTranscript.contains(excludedPhrase) {
            return false
        }

        for explicitPhrase in explicitPhrases where normalizedTranscript.contains(explicitPhrase) {
            return true
        }

        return false
    }
}
