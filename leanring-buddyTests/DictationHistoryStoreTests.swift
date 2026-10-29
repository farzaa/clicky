//
//  DictationHistoryStoreTests.swift
//  leanring-buddyTests
//
//  Covers the local dictation history: recording, status transitions,
//  persistence, retention, the on/off switch, and on-disk privacy settings.
//

import Foundation
import Testing
@testable import Clicky

/// Lets tests move time forward to exercise age-based retention.
private final class AdjustableTestClock {
    var currentDate: Date

    init(currentDate: Date) {
        self.currentDate = currentDate
    }
}

/// An isolated history file + UserDefaults suite per test, so tests never
/// touch the real app's history or settings.
private struct DictationHistoryTestEnvironment {
    let temporaryDirectoryURL: URL
    let historyFileURL: URL
    let userDefaultsSuiteName: String
    let userDefaults: UserDefaults
    let clock: AdjustableTestClock

    init() {
        temporaryDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationHistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        historyFileURL = temporaryDirectoryURL
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("DictationHistory.json")
        userDefaultsSuiteName = "DictationHistoryStoreTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: userDefaultsSuiteName)!
        clock = AdjustableTestClock(currentDate: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @MainActor
    func makeStore() -> DictationHistoryStore {
        let clock = self.clock
        return DictationHistoryStore(
            historyFileURL: historyFileURL,
            userDefaults: userDefaults,
            currentDateProvider: { clock.currentDate }
        )
    }

    var historyFileExists: Bool {
        FileManager.default.fileExists(atPath: historyFileURL.path)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: temporaryDirectoryURL)
        userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
    }
}

@MainActor
struct DictationHistoryStoreTests {

    // MARK: - Recording

    @Test func recordsSendingEntriesNewestFirst() {
        let testEnvironment = DictationHistoryTestEnvironment()
        defer { testEnvironment.cleanUp() }
        let dictationHistoryStore = testEnvironment.makeStore()

        dictationHistoryStore.recordSendingEntry(text: "first message")
        testEnvironment.clock.currentDate.addTimeInterval(5)
        dictationHistoryStore.recordSendingEntry(text: "second message")

        #expect(dictationHistoryStore.entries.map(\.text) == ["second message", "first message"])
        #expect(dictationHistoryStore.entries.allSatisfy { $0.status == .sending })
    }

    @Test func trimsWhitespaceAndIgnoresEmptyText() {
        let testEnvironment = DictationHistoryTestEnvironment()
        defer { testEnvironment.cleanUp() }
        let dictationHistoryStore = testEnvironment.makeStore()

        let emptyEntryID = dictationHistoryStore.recordSendingEntry(text: "   \n  ")
        let trimmedEntryID = dictationHistoryStore.recordSendingEntry(text: "  hello clicky \n")

        #expect(emptyEntryID == nil)
        #expect(trimmedEntryID != nil)
        #expect(dictationHistoryStore.entries.map(\.text) == ["hello clicky"])
    }

    @Test func recordsFailedEntryWithReason() {
        let testEnvironment = DictationHistoryTestEnvironment()
        defer { testEnvironment.cleanUp() }
        let dictationHistoryStore = testEnvironment.makeStore()

        dictationHistoryStore.recordFailedEntry(text: "half a sentence", failureReason: "Transcription stopped.")

        #expect(dictationHistoryStore.entries.first?.status == .failed)
        #expect(dictationHistoryStore.entries.first?.failureReason == "Transcription stopped.")
    }

    // MARK: - Status Transitions

    @Test func markingSentAndFailedUpdatesStatusAndReason() {
        let testEnvironment = DictationHistoryTestEnvironment()
        defer { testEnvironment.cleanUp() }
        let dictationHistoryStore = testEnvironment.makeStore()

        let entryID = dictationHistoryStore.recordSendingEntry(text: "what's this button")

        dictationHistoryStore.markEntryFailed(id: entryID, failureReason: "Couldn't get a reply from Clicky.")
        #expect(dictationHistoryStore.entries.first?.status == .failed)
        #expect(dictationHistoryStore.entries.first?.failureReason == "Couldn't get a reply from Clicky.")

        // "Ask again" moves it back to sending and clears the old reason
        dictationHistoryStore.markEntrySending(id: entryID)
        #expect(dictationHistoryStore.entries.first?.status == .sending)
        #expect(dictationHistoryStore.entries.first?.failureReason == nil)

        dictationHistoryStore.markEntrySent(id: entryID)
        #expect(dictationHistoryStore.entries.first?.status == .sent)
        #expect(dictationHistoryStore.entries.first?.failureReason == nil)
    }

    @Test func interruptionOnlyAppliesToEntriesStillSending() {
        let testEnvironment = DictationHistoryTestEnvironment()
        defer { testEnvironment.cleanUp() }
        let dictationHistoryStore = testEnvironment.makeStore()

        let sentEntryID = dictationHistoryStore.recordSendingEntry(text: "already answered")
        dictationHistoryStore.markEntrySent(id: sentEntryID)
        let failedEntryID = dictationHistoryStore.recordSendingEntry(text: "already failed")
        dictationHistoryStore.markEntryFailed(id: failedEntryID, failureReason: "network")
        let sendingEntryID = dictationHistoryStore.recordSendingEntry(text: "still in flight")

        dictationHistoryStore.markEntryInterrupted(id: sentEntryID)
        dictationHistoryStore.markEntryInterrupted(id: failedEntryID)
        dictationHistoryStore.markEntryInterrupted(id: sendingEntryID)

        let statusesByText = Dictionary(uniqueKeysWithValues: dictationHistoryStore.entries.map { ($0.text, $0.status) })
        #expect(statusesByText["already answered"] == .sent)
        #expect(statusesByText["already failed"] == .failed)
        #expect(statusesByText["still in flight"] == .interrupted)
    }

    @Test func statusUpdatesForNilOrDeletedEntriesAreIgnored() {
        let testEnvironment = DictationHistoryTestEnvironment()
        defer { testEnvironment.cleanUp() }
        let dictationHistoryStore = testEnvironment.makeStore()

        let entryID = dictationHistoryStore.recordSendingEntry(text: "deleted mid-request")
        dictationHistoryStore.deleteEntry(id: entryID!)

        dictationHistoryStore.markEntrySent(id: entryID)
        dictationHistoryStore.markEntryFailed(id: nil, failureReason: "ignored")

        #expect(dictationHistoryStore.entries.isEmpty)
    }

    // MARK: - Persistence

    @Test func entriesPersistAcrossStoreInstances() {
        let testEnvironment = DictationHistoryTestEnvironment()
        defer { testEnvironment.cleanUp() }

        let firstStore = testEnvironment.makeStore()
        let entryID = firstStore.recordSendingEntry(text: "remember me")
        firstStore.markEntryFailed(id: entryID, failureReason: "network")

        let reloadedStore = testEnvironment.makeStore()

        #expect(reloadedStore.entries == firstStore.entries)
        #expect(reloadedStore.entries.first?.status == .failed)
    }

    @Test func entriesStillSendingWhenAppQuitBecomeInterruptedOnLaunch() {
        let testEnvironment = DictationHistoryTestEnvironment()
        defer { testEnvironment.cleanUp() }

        let firstStore = testEnvironment.makeStore()
        firstStore.recordSendingEntry(text: "in flight at quit")

        let reloadedStore = testEnvironment.makeStore()

        #expect(reloadedStore.entries.first?.status == .interrupted)
        #expect(reloadedStore.entries.first?.failureReason == DictationHistoryStore.interruptedByQuitFailureReason)

        // The resolved status is written back so it's stable across launches
        let secondReloadedStore = testEnvironment.makeStore()
        #expect(secondReloadedStore.entries.first?.status == .interrupted)
    }

    @Test func corruptHistoryFileStartsEmptyAndRecovers() throws {
        let testEnvironment = DictationHistoryTestEnvironment()
        defer { testEnvironment.cleanUp() }

        try FileManager.default.createDirectory(
            at: testEnvironment.historyFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: testEnvironment.historyFileURL)

        let dictationHistoryStore = testEnvironment.makeStore()
        #expect(dictationHistoryStore.entries.isEmpty)

        dictationHistoryStore.recordSendingEntry(text: "fresh start")
        let reloadedStore = testEnvironment.makeStore()
        #expect(reloadedStore.entries.map(\.text) == ["fresh start"])
    }

    @Test func historyFileIsPrivateAndExcludedFromBackup() throws {
        let testEnvironment = DictationHistoryTestEnvironment()
        defer { testEnvironment.cleanUp() }
        let dictationHistoryStore = testEnvironment.makeStore()

        dictationHistoryStore.recordSendingEntry(text: "sensitive words")

        let fileAttributes = try FileManager.default.attributesOfItem(atPath: testEnvironment.historyFileURL.path)
        let posixPermissions = (fileAttributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(posixPermissions == 0o600)

        let resourceValues = try testEnvironment.historyFileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(resourceValues.isExcludedFromBackup == true)
    }

    // MARK: - Deleting

    @Test func deletingEntriesRemovesThemAndClearingAllRemovesTheFile() {
        let testEnvironment = DictationHistoryTestEnvironment()
        defer { testEnvironment.cleanUp() }
        let dictationHistoryStore = testEnvironment.makeStore()

        let firstEntryID = dictationHistoryStore.recordSendingEntry(text: "one")
        dictationHistoryStore.recordSendingEntry(text: "two")
        #expect(testEnvironment.historyFileExists)

        dictationHistoryStore.deleteEntry(id: firstEntryID!)
        #expect(dictationHistoryStore.entries.map(\.text) == ["two"])
        #expect(testEnvironment.makeStore().entries.map(\.text) == ["two"])

        dictationHistoryStore.deleteAllEntries()
        #expect(dictationHistoryStore.entries.isEmpty)
        #expect(!testEnvironment.historyFileExists)
    }

    // MARK: - Enable / Disable

    @Test func historyIsEnabledByDefault() {
        let testEnvironment = DictationHistoryTestEnvironment()
        defer { testEnvironment.cleanUp() }

        #expect(testEnvironment.makeStore().isHistoryEnabled)
    }

    @Test func disabledHistoryRecordsNothing() {
        let testEnvironment = DictationHistoryTestEnvironment()
        defer { testEnvironment.cleanUp() }
        let dictationHistoryStore = testEnvironment.makeStore()

        dictationHistoryStore.setHistoryEnabled(false)
        let sendingEntryID = dictationHistoryStore.recordSendingEntry(text: "not saved")
        let failedEntryID = dictationHistoryStore.recordFailedEntry(text: "not saved either", failureReason: "x")

        #expect(sendingEntryID == nil)
        #expect(failedEntryID == nil)
        #expect(dictationHistoryStore.entries.isEmpty)
        #expect(!testEnvironment.historyFileExists)
    }

    @Test func disablingHistoryDeletesSavedEntriesAndPersistsTheChoice() {
        let testEnvironment = DictationHistoryTestEnvironment()
        defer { testEnvironment.cleanUp() }
        let dictationHistoryStore = testEnvironment.makeStore()

        dictationHistoryStore.recordSendingEntry(text: "about to be wiped")
        #expect(testEnvironment.historyFileExists)

        dictationHistoryStore.setHistoryEnabled(false)

        #expect(dictationHistoryStore.entries.isEmpty)
        #expect(!testEnvironment.historyFileExists)

        let reloadedStore = testEnvironment.makeStore()
        #expect(!reloadedStore.isHistoryEnabled)
        #expect(reloadedStore.entries.isEmpty)

        reloadedStore.setHistoryEnabled(true)
        #expect(reloadedStore.recordSendingEntry(text: "back on") != nil)
    }

    // MARK: - Retention

    @Test func maximumEntryCountDropsOldestEntries() {
        let testEnvironment = DictationHistoryTestEnvironment()
        defer { testEnvironment.cleanUp() }
        let dictationHistoryStore = testEnvironment.makeStore()
        dictationHistoryStore.setMaximumEntryCount(10)

        for messageNumber in 1...12 {
            dictationHistoryStore.recordSendingEntry(text: "message \(messageNumber)")
            testEnvironment.clock.currentDate.addTimeInterval(1)
        }

        #expect(dictationHistoryStore.entries.count == 10)
        #expect(dictationHistoryStore.entries.first?.text == "message 12")
        #expect(dictationHistoryStore.entries.last?.text == "message 3")
    }

    @Test func loweringMaximumEntryCountPrunesImmediately() {
        let testEnvironment = DictationHistoryTestEnvironment()
        defer { testEnvironment.cleanUp() }
        let dictationHistoryStore = testEnvironment.makeStore()
        dictationHistoryStore.setMaximumEntryCount(50)

        for messageNumber in 1...30 {
            dictationHistoryStore.recordSendingEntry(text: "message \(messageNumber)")
            testEnvironment.clock.currentDate.addTimeInterval(1)
        }
        #expect(dictationHistoryStore.entries.count == 30)

        dictationHistoryStore.setMaximumEntryCount(25)
        #expect(dictationHistoryStore.entries.count == 25)
        #expect(testEnvironment.makeStore().entries.count == 25)
    }

    @Test func unsupportedMaximumEntryCountIsRejected() {
        let testEnvironment = DictationHistoryTestEnvironment()
        defer { testEnvironment.cleanUp() }
        let dictationHistoryStore = testEnvironment.makeStore()

        dictationHistoryStore.setMaximumEntryCount(3)

        #expect(dictationHistoryStore.maximumEntryCount == DictationHistoryRetentionPolicy.defaultMaximumEntryCount)
    }

    @Test func expiredEntriesAreRemovedAfterTheRetentionPeriod() {
        let testEnvironment = DictationHistoryTestEnvironment()
        defer { testEnvironment.cleanUp() }
        let dictationHistoryStore = testEnvironment.makeStore()
        dictationHistoryStore.setRetentionPeriod(.oneDay)

        dictationHistoryStore.recordSendingEntry(text: "old message")
        testEnvironment.clock.currentDate.addTimeInterval(20 * 60 * 60)
        dictationHistoryStore.recordSendingEntry(text: "newer message")

        // 25 hours after the first message: only the newer one is inside the window
        testEnvironment.clock.currentDate.addTimeInterval(5 * 60 * 60)
        dictationHistoryStore.removeExpiredEntries()

        #expect(dictationHistoryStore.entries.map(\.text) == ["newer message"])
    }

    @Test func expiredEntriesAreRemovedOnLaunch() {
        let testEnvironment = DictationHistoryTestEnvironment()
        defer { testEnvironment.cleanUp() }
        let dictationHistoryStore = testEnvironment.makeStore()
        dictationHistoryStore.setRetentionPeriod(.sevenDays)
        dictationHistoryStore.recordSendingEntry(text: "last week")

        testEnvironment.clock.currentDate.addTimeInterval(8 * 24 * 60 * 60)
        let reloadedStore = testEnvironment.makeStore()

        #expect(reloadedStore.entries.isEmpty)
        #expect(!testEnvironment.historyFileExists)
    }

    @Test func shorteningRetentionPeriodPrunesImmediately() {
        let testEnvironment = DictationHistoryTestEnvironment()
        defer { testEnvironment.cleanUp() }
        let dictationHistoryStore = testEnvironment.makeStore()
        dictationHistoryStore.setRetentionPeriod(.thirtyDays)
        dictationHistoryStore.recordSendingEntry(text: "three days old")

        testEnvironment.clock.currentDate.addTimeInterval(3 * 24 * 60 * 60)
        dictationHistoryStore.setRetentionPeriod(.oneDay)

        #expect(dictationHistoryStore.entries.isEmpty)
    }

    @Test func retentionSettingsPersist() {
        let testEnvironment = DictationHistoryTestEnvironment()
        defer { testEnvironment.cleanUp() }
        let dictationHistoryStore = testEnvironment.makeStore()

        dictationHistoryStore.setRetentionPeriod(.forever)
        dictationHistoryStore.setMaximumEntryCount(100)

        let reloadedStore = testEnvironment.makeStore()
        #expect(reloadedStore.retentionPeriod == .forever)
        #expect(reloadedStore.maximumEntryCount == 100)
    }

    @Test func defaultRetentionSettingsAreUsedWhenNothingIsSaved() {
        let testEnvironment = DictationHistoryTestEnvironment()
        defer { testEnvironment.cleanUp() }
        testEnvironment.userDefaults.set(7, forKey: DictationHistoryStore.maximumEntryCountUserDefaultsKey)
        testEnvironment.userDefaults.set("fortnight", forKey: DictationHistoryStore.retentionPeriodUserDefaultsKey)

        let dictationHistoryStore = testEnvironment.makeStore()

        #expect(dictationHistoryStore.maximumEntryCount == DictationHistoryRetentionPolicy.defaultMaximumEntryCount)
        #expect(dictationHistoryStore.retentionPeriod == DictationHistoryRetentionPolicy.defaultRetentionPeriod)
    }
}

// The app target defaults to MainActor isolation, so its types are used from the main actor here too.
@MainActor
struct DictationHistoryRetentionPolicyTests {
    private let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeEntry(text: String, ageInSeconds: TimeInterval) -> DictationHistoryEntry {
        DictationHistoryEntry(
            id: UUID(),
            text: text,
            createdAt: referenceDate.addingTimeInterval(-ageInSeconds),
            status: .sent,
            failureReason: nil
        )
    }

    @Test func sortsNewestFirstAndAppliesCountLimit() {
        let entries = [
            makeEntry(text: "oldest", ageInSeconds: 300),
            makeEntry(text: "newest", ageInSeconds: 10),
            makeEntry(text: "middle", ageInSeconds: 100)
        ]

        let remainingEntries = DictationHistoryRetentionPolicy.entriesRemainingAfterRetention(
            entries: entries,
            maximumEntryCount: 2,
            retentionPeriod: .forever,
            currentDate: referenceDate
        )

        #expect(remainingEntries.map(\.text) == ["newest", "middle"])
    }

    @Test func foreverKeepsVeryOldEntries() {
        let entries = [makeEntry(text: "ancient", ageInSeconds: 5 * 365 * 24 * 60 * 60)]

        let remainingEntries = DictationHistoryRetentionPolicy.entriesRemainingAfterRetention(
            entries: entries,
            maximumEntryCount: 25,
            retentionPeriod: .forever,
            currentDate: referenceDate
        )

        #expect(remainingEntries.count == 1)
    }

    @Test func entryExactlyAtTheRetentionBoundaryIsKept() {
        let secondsPerDay: TimeInterval = 24 * 60 * 60
        let entries = [
            makeEntry(text: "exactly one day", ageInSeconds: secondsPerDay),
            makeEntry(text: "just over one day", ageInSeconds: secondsPerDay + 1)
        ]

        let remainingEntries = DictationHistoryRetentionPolicy.entriesRemainingAfterRetention(
            entries: entries,
            maximumEntryCount: 25,
            retentionPeriod: .oneDay,
            currentDate: referenceDate
        )

        #expect(remainingEntries.map(\.text) == ["exactly one day"])
    }
}
