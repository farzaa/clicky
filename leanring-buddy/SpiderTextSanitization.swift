//
//  SpiderTextSanitization.swift
//  leanring-buddy
//
//  Shared bounded text normalization for local storage, Worker payloads, and
//  decoded guide responses. This never logs or persists raw sensitive content.
//

import Foundation

extension String {
    func spiderSanitizedSingleLine(maxCharacters: Int) -> String {
        spiderSanitizedMultiline(maxCharacters: maxCharacters)
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func spiderSanitizedMultiline(maxCharacters: Int) -> String {
        let cleanedValue = replacingOccurrences(of: "\u{0000}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleanedValue.count > maxCharacters else {
            return cleanedValue
        }

        let cutoffIndex = cleanedValue.index(cleanedValue.startIndex, offsetBy: maxCharacters)
        return String(cleanedValue[..<cutoffIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func spiderSanitizedShortDialogue(
        maxCharacters: Int,
        maxWords: Int,
        maxSentences: Int
    ) -> String {
        let singleLine = spiderSanitizedSingleLine(maxCharacters: SpiderContentLimits.maxGuideSpokenTextCharacters)
        guard !singleLine.isEmpty else { return "" }

        let sentenceBounded = singleLine.spiderPrefixSentences(maxSentences)
        let words = sentenceBounded.split(whereSeparator: { $0.isWhitespace })
        let wordBounded = words.prefix(maxWords).joined(separator: " ")

        return wordBounded.spiderSanitizedSingleLine(maxCharacters: maxCharacters)
    }

    private func spiderPrefixSentences(_ maxSentences: Int) -> String {
        guard maxSentences > 0 else { return "" }

        var collected = ""
        var sentenceCount = 0
        for character in self {
            collected.append(character)
            if ".!?".contains(character) {
                sentenceCount += 1
                if sentenceCount >= maxSentences {
                    break
                }
            }
        }

        return collected.isEmpty ? self : collected
    }
}

extension Array where Element == String {
    func spiderSanitizedList(
        maxItems: Int = SpiderContentLimits.maxProjectListItems,
        maxCharacters: Int = SpiderContentLimits.maxProjectListItemCharacters
    ) -> [String] {
        var seenValues = Set<String>()
        var sanitizedValues: [String] = []

        for value in self {
            let sanitizedValue = value.spiderSanitizedSingleLine(
                maxCharacters: maxCharacters
            )
            guard !sanitizedValue.isEmpty else { continue }

            let normalizedValue = sanitizedValue.lowercased()
            guard !seenValues.contains(normalizedValue) else { continue }

            seenValues.insert(normalizedValue)
            sanitizedValues.append(sanitizedValue)

            if sanitizedValues.count >= maxItems {
                break
            }
        }

        return sanitizedValues
    }
}
