//
//  PersonalContextAssembler.swift
//  leanring-buddy
//
//  Builds a turn-scoped user message with retrieved vault excerpts.
//

import Foundation

enum PersonalContextAssembler {
    static func buildUserPrompt(
        originalTranscript: String,
        retrievedChunks: [PersonalKnowledgeChunk],
        maxTotalCharacters: Int = 3000
    ) -> String {
        guard !retrievedChunks.isEmpty else {
            return originalTranscript
        }

        var usedCharacters = 0
        var renderedSections: [String] = []

        for chunk in retrievedChunks {
            let section = """
            [from \(chunk.sourceLabel)]
            \(chunk.excerpt)
            """
            if usedCharacters + section.count > maxTotalCharacters, !renderedSections.isEmpty {
                break
            }
            renderedSections.append(section)
            usedCharacters += section.count
        }

        guard !renderedSections.isEmpty else {
            return originalTranscript
        }

        return """
        the user is asking about their personal notes or internal knowledge. use the excerpts below when answering. if nothing is relevant, say you could not find matching notes in their vault.

        --- relevant notes ---
        \(renderedSections.joined(separator: "\n\n"))
        --- end notes ---

        user question: \(originalTranscript)
        """
    }
}
