//
//  DotConversationHistoryStore.swift
//  leanring-buddy
//
//  JSON file persistence for the cross-turn conversation thread. Lives
//  separately from `DotMemoryStore` because the two solve different
//  problems: memory holds durable user-facts the model writes via the
//  memory tool; conversation history is the running transcript so the
//  model can carry a thread across turns and app restarts.
//

import Foundation

/// One past push-to-talk exchange: the user's spoken transcript and the
/// model's spoken response, with the wall-clock time it was recorded.
/// `recordedAt` powers future compaction-by-time-range; today only the
/// count-based compaction in `CompanionManager` uses it.
struct ConversationExchange: Codable, Sendable {
    let userTranscript: String
    let assistantResponse: String
    let recordedAt: Date
}

@MainActor
enum DotConversationHistoryStore {

    /// Settable so unit tests can swap in a temp file location without
    /// touching the user's real Application Support directory. Production
    /// code never reassigns this.
    static var onDiskHistoryFileURL: URL = computeDefaultProductionHistoryFileURL()

    private static func computeDefaultProductionHistoryFileURL() -> URL {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupportURL
            .appendingPathComponent("Dot", isDirectory: true)
            .appendingPathComponent("conversation_history.json", isDirectory: false)
    }

    /// Load the persisted exchanges, or [] if the file doesn't exist or
    /// can't be decoded. We swallow decode errors silently — a corrupted
    /// history file should not block app launch; the user just starts the
    /// next session fresh.
    static func loadPersistedExchanges() -> [ConversationExchange] {
        guard FileManager.default.fileExists(atPath: onDiskHistoryFileURL.path),
              let fileData = try? Data(contentsOf: onDiskHistoryFileURL) else {
            return []
        }
        let jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601
        do {
            return try jsonDecoder.decode([ConversationExchange].self, from: fileData)
        } catch {
            DotDebugLogger.log("conversation.history", "failed to decode persisted history; starting fresh", metadata: [
                "error": error.localizedDescription,
                "fileSizeBytes": fileData.count
            ])
            return []
        }
    }

    /// Atomically write the full exchange list to disk. Called after every
    /// turn so a crash/quit between writes loses at most the in-flight
    /// turn (which the model didn't even finish processing).
    static func persistExchanges(_ exchanges: [ConversationExchange]) {
        let parentDirectoryURL = onDiskHistoryFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: parentDirectoryURL,
            withIntermediateDirectories: true
        )
        let jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .iso8601
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let encodedData = try jsonEncoder.encode(exchanges)
            try encodedData.write(to: onDiskHistoryFileURL, options: [.atomic])
        } catch {
            DotDebugLogger.log("conversation.history", "failed to persist history", metadata: [
                "error": error.localizedDescription,
                "exchangeCount": exchanges.count
            ])
        }
    }

    /// Wipe the persisted history. Wired up for the eventual "Forget our
    /// conversation" UI button; not called automatically.
    static func clearPersistedHistory() {
        try? FileManager.default.removeItem(at: onDiskHistoryFileURL)
    }
}
