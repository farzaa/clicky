//
//  DictationHistoryStore.swift
//  leanring-buddy
//
//  Local-only history of recent push-to-talk transcripts. Every finalized
//  transcript is saved before it's sent to Claude, so if anything goes wrong
//  (screenshot or network failure, TTS failure, the transcription stopping
//  early, or the user interrupting) the text can be copied, inserted, or sent
//  again instead of being dictated from scratch.
//
//  Entries live in a JSON file in this Mac's Application Support folder. The
//  file is never uploaded or synced, is readable only by the current user,
//  and is excluded from backups.
//

import Combine
import Foundation

enum DictationHistoryEntryStatus: String, Codable {
    /// The transcript is being sent to Claude right now.
    case sending
    /// Claude received the transcript and replied.
    case sent
    /// Something went wrong before the user got a reply.
    case failed
    /// The user started a new push-to-talk (or Clicky quit) before Claude replied.
    case interrupted
}

struct DictationHistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let createdAt: Date
    var status: DictationHistoryEntryStatus
    /// Short user-facing explanation shown under failed or interrupted entries.
    var failureReason: String?
}

enum DictationHistoryRetentionPeriod: String, CaseIterable, Identifiable {
    case oneDay
    case sevenDays
    case thirtyDays
    case forever

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .oneDay:
            return "1 day"
        case .sevenDays:
            return "7 days"
        case .thirtyDays:
            return "30 days"
        case .forever:
            return "Forever"
        }
    }

    /// Nil means entries never expire by age (they can still be removed by the entry-count limit).
    var maximumEntryAgeInSeconds: TimeInterval? {
        let secondsPerDay: TimeInterval = 24 * 60 * 60
        switch self {
        case .oneDay:
            return secondsPerDay
        case .sevenDays:
            return 7 * secondsPerDay
        case .thirtyDays:
            return 30 * secondsPerDay
        case .forever:
            return nil
        }
    }
}

/// Pure pruning rules, kept separate from the store so they're easy to reason about and test.
enum DictationHistoryRetentionPolicy {
    static let maximumEntryCountOptions = [10, 25, 50, 100]
    static let defaultMaximumEntryCount = 25
    static let defaultRetentionPeriod: DictationHistoryRetentionPeriod = .sevenDays

    /// Returns the entries that should be kept, newest first: anything older than the
    /// retention period is dropped, then only the newest `maximumEntryCount` are kept.
    static func entriesRemainingAfterRetention(
        entries: [DictationHistoryEntry],
        maximumEntryCount: Int,
        retentionPeriod: DictationHistoryRetentionPeriod,
        currentDate: Date
    ) -> [DictationHistoryEntry] {
        let entriesSortedNewestFirst = entries.sorted { firstEntry, secondEntry in
            firstEntry.createdAt > secondEntry.createdAt
        }

        let entriesWithinRetentionPeriod: [DictationHistoryEntry]
        if let maximumEntryAgeInSeconds = retentionPeriod.maximumEntryAgeInSeconds {
            entriesWithinRetentionPeriod = entriesSortedNewestFirst.filter { entry in
                currentDate.timeIntervalSince(entry.createdAt) <= maximumEntryAgeInSeconds
            }
        } else {
            entriesWithinRetentionPeriod = entriesSortedNewestFirst
        }

        return Array(entriesWithinRetentionPeriod.prefix(max(0, maximumEntryCount)))
    }
}

@MainActor
final class DictationHistoryStore: ObservableObject {
    static let isHistoryEnabledUserDefaultsKey = "isDictationHistoryEnabled"
    static let maximumEntryCountUserDefaultsKey = "dictationHistoryMaximumEntryCount"
    static let retentionPeriodUserDefaultsKey = "dictationHistoryRetentionPeriod"

    // Nonisolated so they can be used as default argument values.
    nonisolated static let interruptedByQuitFailureReason = "Clicky quit before replying."
    nonisolated static let interruptedByNewMessageFailureReason = "You started a new message before Clicky replied."

    /// Newest entry first.
    @Published private(set) var entries: [DictationHistoryEntry] = []
    @Published private(set) var isHistoryEnabled: Bool
    @Published private(set) var maximumEntryCount: Int
    @Published private(set) var retentionPeriod: DictationHistoryRetentionPeriod

    private let historyFileURL: URL
    private let userDefaults: UserDefaults
    private let currentDateProvider: () -> Date

    /// `~/Library/Application Support/<bundle id>/DictationHistory.json`
    /// Nonisolated because it's used as a default argument, and default
    /// arguments are evaluated outside the main actor.
    nonisolated static func defaultHistoryFileURL() -> URL {
        let applicationSupportDirectoryURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let appSpecificDirectoryName = Bundle.main.bundleIdentifier ?? "leanring-buddy"

        return applicationSupportDirectoryURL
            .appendingPathComponent(appSpecificDirectoryName, isDirectory: true)
            .appendingPathComponent("DictationHistory.json", isDirectory: false)
    }

    init(
        historyFileURL: URL = DictationHistoryStore.defaultHistoryFileURL(),
        userDefaults: UserDefaults = .standard,
        currentDateProvider: @escaping () -> Date = { Date() }
    ) {
        self.historyFileURL = historyFileURL
        self.userDefaults = userDefaults
        self.currentDateProvider = currentDateProvider

        // History is on by default so recovery works out of the box. It only ever
        // lives on this Mac, and the panel says so right next to the toggle.
        self.isHistoryEnabled = userDefaults.object(forKey: Self.isHistoryEnabledUserDefaultsKey) == nil
            ? true
            : userDefaults.bool(forKey: Self.isHistoryEnabledUserDefaultsKey)

        let savedMaximumEntryCount = userDefaults.integer(forKey: Self.maximumEntryCountUserDefaultsKey)
        self.maximumEntryCount = DictationHistoryRetentionPolicy.maximumEntryCountOptions.contains(savedMaximumEntryCount)
            ? savedMaximumEntryCount
            : DictationHistoryRetentionPolicy.defaultMaximumEntryCount

        let savedRetentionPeriodRawValue = userDefaults.string(forKey: Self.retentionPeriodUserDefaultsKey) ?? ""
        self.retentionPeriod = DictationHistoryRetentionPeriod(rawValue: savedRetentionPeriodRawValue)
            ?? DictationHistoryRetentionPolicy.defaultRetentionPeriod

        loadEntriesFromDisk()
    }

    // MARK: - Recording

    /// Saves a transcript that's about to be sent to Claude. Returns the new entry's
    /// id so the caller can report the outcome, or nil when history is turned off.
    @discardableResult
    func recordSendingEntry(text: String) -> UUID? {
        return insertNewEntry(text: text, status: .sending, failureReason: nil)
    }

    /// Saves text that never made it to Claude at all (for example, a partial
    /// transcript from a transcription session that errored out).
    @discardableResult
    func recordFailedEntry(text: String, failureReason: String) -> UUID? {
        return insertNewEntry(text: text, status: .failed, failureReason: failureReason)
    }

    // MARK: - Status Updates
    //
    // These take an optional id so callers can pass through whatever
    // recordSendingEntry returned without branching on whether history is on.
    // Unknown or nil ids are ignored (the entry may have been deleted mid-request).

    /// Marks an existing entry as being sent again (used by "Ask again").
    func markEntrySending(id entryID: UUID?) {
        updateEntry(id: entryID) { entry in
            entry.status = .sending
            entry.failureReason = nil
        }
    }

    func markEntrySent(id entryID: UUID?) {
        updateEntry(id: entryID) { entry in
            entry.status = .sent
            entry.failureReason = nil
        }
    }

    func markEntryFailed(id entryID: UUID?, failureReason: String) {
        updateEntry(id: entryID) { entry in
            entry.status = .failed
            entry.failureReason = failureReason
        }
    }

    /// Only moves an entry out of `.sending`, so a cancellation that races with a
    /// completed request never overwrites a sent or failed outcome.
    func markEntryInterrupted(id entryID: UUID?, failureReason: String = DictationHistoryStore.interruptedByNewMessageFailureReason) {
        guard let entryID,
              let existingEntry = entries.first(where: { $0.id == entryID }),
              existingEntry.status == .sending else { return }

        updateEntry(id: entryID) { entry in
            entry.status = .interrupted
            entry.failureReason = failureReason
        }
    }

    // MARK: - Deleting

    func deleteEntry(id entryID: UUID) {
        let entriesAfterDeletion = entries.filter { $0.id != entryID }
        guard entriesAfterDeletion.count != entries.count else { return }
        entries = entriesAfterDeletion
        saveEntriesToDisk()
    }

    func deleteAllEntries() {
        entries = []
        saveEntriesToDisk()
    }

    /// Drops entries that have aged out. Called on launch, on every new entry,
    /// when settings change, when the history view opens, and on a periodic timer.
    func removeExpiredEntries() {
        let entriesAfterRetention = DictationHistoryRetentionPolicy.entriesRemainingAfterRetention(
            entries: entries,
            maximumEntryCount: maximumEntryCount,
            retentionPeriod: retentionPeriod,
            currentDate: currentDateProvider()
        )
        guard entriesAfterRetention != entries else { return }
        entries = entriesAfterRetention
        saveEntriesToDisk()
    }

    // MARK: - Settings

    /// Turning history off also deletes everything already saved, so there's
    /// never a hidden file of old dictations left behind on disk.
    func setHistoryEnabled(_ isEnabled: Bool) {
        isHistoryEnabled = isEnabled
        userDefaults.set(isEnabled, forKey: Self.isHistoryEnabledUserDefaultsKey)

        if !isEnabled {
            deleteAllEntries()
        }
    }

    func setMaximumEntryCount(_ newMaximumEntryCount: Int) {
        guard DictationHistoryRetentionPolicy.maximumEntryCountOptions.contains(newMaximumEntryCount) else { return }
        maximumEntryCount = newMaximumEntryCount
        userDefaults.set(newMaximumEntryCount, forKey: Self.maximumEntryCountUserDefaultsKey)
        removeExpiredEntries()
    }

    func setRetentionPeriod(_ newRetentionPeriod: DictationHistoryRetentionPeriod) {
        retentionPeriod = newRetentionPeriod
        userDefaults.set(newRetentionPeriod.rawValue, forKey: Self.retentionPeriodUserDefaultsKey)
        removeExpiredEntries()
    }

    // MARK: - Private

    private func insertNewEntry(
        text: String,
        status: DictationHistoryEntryStatus,
        failureReason: String?
    ) -> UUID? {
        guard isHistoryEnabled else { return nil }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return nil }

        let newEntry = DictationHistoryEntry(
            id: UUID(),
            text: trimmedText,
            createdAt: currentDateProvider(),
            status: status,
            failureReason: failureReason
        )

        entries.insert(newEntry, at: 0)
        entries = DictationHistoryRetentionPolicy.entriesRemainingAfterRetention(
            entries: entries,
            maximumEntryCount: maximumEntryCount,
            retentionPeriod: retentionPeriod,
            currentDate: currentDateProvider()
        )
        saveEntriesToDisk()
        return newEntry.id
    }

    private func updateEntry(id entryID: UUID?, applyChanges: (inout DictationHistoryEntry) -> Void) {
        guard let entryID,
              let entryIndex = entries.firstIndex(where: { $0.id == entryID }) else { return }

        var updatedEntry = entries[entryIndex]
        applyChanges(&updatedEntry)
        guard updatedEntry != entries[entryIndex] else { return }

        entries[entryIndex] = updatedEntry
        saveEntriesToDisk()
    }

    private func loadEntriesFromDisk() {
        guard isHistoryEnabled else {
            // Defensive: if history is off, make sure nothing is lingering on disk.
            removeHistoryFileIfPresent()
            return
        }

        guard FileManager.default.fileExists(atPath: historyFileURL.path) else { return }

        do {
            let historyFileData = try Data(contentsOf: historyFileURL)
            let decodedEntries = try JSONDecoder().decode([DictationHistoryEntry].self, from: historyFileData)

            // Anything still "sending" was in flight when Clicky last quit, so
            // Claude never replied. Surface it as interrupted so it can be recovered.
            let entriesWithStaleSendsResolved = decodedEntries.map { entry -> DictationHistoryEntry in
                guard entry.status == .sending else { return entry }
                var interruptedEntry = entry
                interruptedEntry.status = .interrupted
                interruptedEntry.failureReason = Self.interruptedByQuitFailureReason
                return interruptedEntry
            }

            entries = DictationHistoryRetentionPolicy.entriesRemainingAfterRetention(
                entries: entriesWithStaleSendsResolved,
                maximumEntryCount: maximumEntryCount,
                retentionPeriod: retentionPeriod,
                currentDate: currentDateProvider()
            )

            if entries != decodedEntries {
                saveEntriesToDisk()
            }
        } catch {
            // A corrupt file shouldn't break push-to-talk. Start fresh; the next
            // save overwrites the unreadable file.
            print("⚠️ Dictation history: couldn't read saved history: \(error)")
            entries = []
        }
    }

    private func saveEntriesToDisk() {
        // An empty history means no file at all, so "Clear all" really removes
        // the dictated text from disk rather than leaving an empty JSON array.
        guard !entries.isEmpty else {
            removeHistoryFileIfPresent()
            return
        }

        do {
            let historyDirectoryURL = historyFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: historyDirectoryURL,
                withIntermediateDirectories: true
            )

            let historyFileData = try JSONEncoder().encode(entries)
            try historyFileData.write(to: historyFileURL, options: [.atomic])

            // Owner read/write only, since this file contains the user's own words.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: historyFileURL.path
            )

            // Keep dictated text out of Time Machine and other backups so it
            // truly stays on this device only.
            var historyFileURLWithResourceValues = historyFileURL
            var backupExclusionResourceValues = URLResourceValues()
            backupExclusionResourceValues.isExcludedFromBackup = true
            try historyFileURLWithResourceValues.setResourceValues(backupExclusionResourceValues)
        } catch {
            print("⚠️ Dictation history: couldn't save history: \(error)")
        }
    }

    private func removeHistoryFileIfPresent() {
        guard FileManager.default.fileExists(atPath: historyFileURL.path) else { return }

        do {
            try FileManager.default.removeItem(at: historyFileURL)
        } catch {
            print("⚠️ Dictation history: couldn't delete history file: \(error)")
        }
    }
}
