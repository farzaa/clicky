//
//  BuddyDictationDraftComposer.swift
//  leanring-buddy
//
//  Text merge policy for inserting a final dictation transcript into a draft.
//

import Foundation

enum BuddyDictationDraftComposer {
    static func compose(existingDraftText: String, transcribedText: String) -> String {
        let trimmedTranscriptText = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTranscriptText.isEmpty else {
            return existingDraftText
        }

        let trimmedExistingDraftText = existingDraftText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedExistingDraftText.isEmpty else {
            return trimmedTranscriptText
        }

        if existingDraftText.hasSuffix(" ") || existingDraftText.hasSuffix("\n") {
            return existingDraftText + trimmedTranscriptText
        }

        return existingDraftText + " " + trimmedTranscriptText
    }
}
