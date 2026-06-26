//
//  BuddyDictationKeytermBuilder.swift
//  leanring-buddy
//
//  Builds privacy-safe product vocabulary hints for speech transcription.
//

import Foundation

enum BuddyDictationKeytermBuilder {
    private static let baseKeyterms = [
        "Spider",
        "Meta Ads",
        "Ads Manager",
        "Ad Mission",
        "Pixel",
        "Purchase",
        "Leads",
        "Traffic",
        "Sales",
        "OpenAI",
        "UTM"
    ]

    static func build(contextualKeyterms: [String]) -> [String] {
        let combinedKeyterms = baseKeyterms
            + SpiderProductFeatures.availableTranscriptionKeyterms
            + contextualKeyterms
        var uniqueNormalizedKeyterms = Set<String>()
        var orderedKeyterms: [String] = []

        for keyterm in combinedKeyterms {
            let trimmedKeyterm = keyterm.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKeyterm.isEmpty else { continue }

            let normalizedKeyterm = trimmedKeyterm.lowercased()
            if uniqueNormalizedKeyterms.contains(normalizedKeyterm) {
                continue
            }

            uniqueNormalizedKeyterms.insert(normalizedKeyterm)
            orderedKeyterms.append(trimmedKeyterm)
        }

        return orderedKeyterms
    }
}
