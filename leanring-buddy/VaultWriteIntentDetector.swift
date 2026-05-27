//
//  VaultWriteIntentDetector.swift
//  leanring-buddy
//
//  Detects explicit vault write requests and confirmation phrases.
//

import Foundation

enum VaultWriteDestination: Equatable {
    case newNote(noteTitle: String, noteContent: String)
    case appendDailyNote(noteContent: String)
    case appendMemory(noteContent: String)
}

struct VaultWriteRequest: Equatable {
    let destination: VaultWriteDestination
    let sourceTranscript: String
}

struct PendingVaultWrite: Equatable, Identifiable {
    let id = UUID()
    let writeRequest: VaultWriteRequest
    let previewTitle: String
    let previewBody: String
    let targetDescription: String

    init(writeRequest: VaultWriteRequest) {
        self.writeRequest = writeRequest

        switch writeRequest.destination {
        case .newNote(let noteTitle, let noteContent):
            previewTitle = noteTitle
            previewBody = noteContent
            targetDescription = "New note · \(noteTitle).md"
        case .appendDailyNote(let noteContent):
            previewTitle = "Daily note"
            previewBody = noteContent
            targetDescription = "Append to today's daily note"
        case .appendMemory(let noteContent):
            previewTitle = "Memory"
            previewBody = noteContent
            targetDescription = "Append to ~/.clicky/brain/MEMORY.md"
        }
    }
}

enum VaultWriteIntentDetector {
    private struct WritePattern {
        let phrase: String
        let destinationBuilder: (String) -> VaultWriteDestination
    }

    private static let writePatterns: [WritePattern] = [
        WritePattern(phrase: "save this to my vault", destinationBuilder: { .newNote(noteTitle: Self.defaultNoteTitle(from: $0), noteContent: $0) }),
        WritePattern(phrase: "save to my vault", destinationBuilder: { .newNote(noteTitle: Self.defaultNoteTitle(from: $0), noteContent: $0) }),
        WritePattern(phrase: "remember in my vault", destinationBuilder: { .newNote(noteTitle: Self.defaultNoteTitle(from: $0), noteContent: $0) }),
        WritePattern(phrase: "remember this in my vault", destinationBuilder: { .newNote(noteTitle: Self.defaultNoteTitle(from: $0), noteContent: $0) }),
        WritePattern(phrase: "add to my daily note", destinationBuilder: { .appendDailyNote(noteContent: $0) }),
        WritePattern(phrase: "append to my daily note", destinationBuilder: { .appendDailyNote(noteContent: $0) }),
        WritePattern(phrase: "save to my daily note", destinationBuilder: { .appendDailyNote(noteContent: $0) }),
        WritePattern(phrase: "remember in my notes", destinationBuilder: { .appendMemory(noteContent: $0) }),
        WritePattern(phrase: "remember this in my notes", destinationBuilder: { .appendMemory(noteContent: $0) }),
        WritePattern(phrase: "update what you know about me", destinationBuilder: { .appendMemory(noteContent: $0) }),
        WritePattern(phrase: "save to my notes", destinationBuilder: { .newNote(noteTitle: Self.defaultNoteTitle(from: $0), noteContent: $0) })
    ]

    private static let confirmationPhrases = [
        "yes save it",
        "yes save",
        "save it",
        "confirm",
        "go ahead",
        "do it",
        "yes do it",
        "that's right",
        "looks good"
    ]

    private static let cancellationPhrases = [
        "cancel",
        "never mind",
        "nevermind",
        "don't save",
        "do not save",
        "no don't save",
        "discard"
    ]

    static func parseWriteRequest(transcript: String) -> VaultWriteRequest? {
        let normalizedTranscript = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalizedTranscript.isEmpty else { return nil }

        for writePattern in writePatterns where normalizedTranscript.contains(writePattern.phrase) {
            let extractedContent = extractContent(from: transcript, afterPhrase: writePattern.phrase)
            guard !extractedContent.isEmpty else { return nil }

            return VaultWriteRequest(
                destination: writePattern.destinationBuilder(extractedContent),
                sourceTranscript: transcript
            )
        }

        return nil
    }

    static func isVaultWriteConfirmation(transcript: String) -> Bool {
        let normalizedTranscript = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalizedTranscript.isEmpty else { return false }

        return confirmationPhrases.contains { normalizedTranscript.contains($0) }
    }

    static func isVaultWriteCancellation(transcript: String) -> Bool {
        let normalizedTranscript = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalizedTranscript.isEmpty else { return false }

        return cancellationPhrases.contains { normalizedTranscript.contains($0) }
    }

    static func isVaultWriteTranscript(_ transcript: String) -> Bool {
        parseWriteRequest(transcript: transcript) != nil
    }

    private static func extractContent(from transcript: String, afterPhrase phrase: String) -> String {
        let lowercasedTranscript = transcript.lowercased()
        guard let phraseRange = lowercasedTranscript.range(of: phrase) else { return "" }

        let contentStartIndex = transcript.index(
            transcript.startIndex,
            offsetBy: lowercasedTranscript.distance(from: lowercasedTranscript.startIndex, to: phraseRange.upperBound)
        )

        var extractedContent = String(transcript[contentStartIndex...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if extractedContent.hasPrefix(":") || extractedContent.hasPrefix(",") {
            extractedContent = String(extractedContent.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if extractedContent.hasPrefix("\""), extractedContent.hasSuffix("\""), extractedContent.count >= 2 {
            extractedContent = String(extractedContent.dropFirst().dropLast())
        }

        return extractedContent.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func defaultNoteTitle(from content: String) -> String {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else { return "Untitled note" }

        let firstLine = trimmedContent
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? trimmedContent

        let shortenedTitle = String(firstLine.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
        return shortenedTitle.isEmpty ? "Untitled note" : shortenedTitle
    }
}
