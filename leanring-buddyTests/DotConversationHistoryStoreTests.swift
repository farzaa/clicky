//
//  DotConversationHistoryStoreTests.swift
//  leanring-buddyTests
//
//  Coverage for the JSON-backed persistence layer that survives app
//  restarts so the model can pick up the conversation thread where it
//  left off. Each test runs against a fresh temp file so the user's real
//  conversation_history.json is never touched.
//

import Testing
import Foundation
@testable import leanring_buddy

@MainActor
@Suite(.serialized)
struct DotConversationHistoryStoreTests {

    // MARK: - Test scaffolding

    /// Swap in a fresh per-test temp file location, run `body`, then
    /// clean up and restore the production URL.
    private static func withFreshHistoryFile<R>(_ body: () throws -> R) rethrows -> R {
        let savedProductionURL = DotConversationHistoryStore.onDiskHistoryFileURL
        let testFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "DotConversationHistoryStoreTests-\(UUID().uuidString).json",
                isDirectory: false
            )
        DotConversationHistoryStore.onDiskHistoryFileURL = testFileURL
        defer {
            try? FileManager.default.removeItem(at: testFileURL)
            DotConversationHistoryStore.onDiskHistoryFileURL = savedProductionURL
        }
        return try body()
    }

    private static func makeExchange(_ user: String, _ assistant: String) -> ConversationExchange {
        return ConversationExchange(
            userTranscript: user,
            assistantResponse: assistant,
            recordedAt: Date()
        )
    }

    // MARK: - loadPersistedExchanges

    @Test func loadReturnsEmptyArrayWhenFileMissing() {
        Self.withFreshHistoryFile {
            let loadedExchanges = DotConversationHistoryStore.loadPersistedExchanges()
            #expect(loadedExchanges.isEmpty)
        }
    }

    @Test func loadReturnsEmptyArrayOnCorruptJson() {
        Self.withFreshHistoryFile {
            try? "this is not json {{ broken".write(
                to: DotConversationHistoryStore.onDiskHistoryFileURL,
                atomically: true,
                encoding: .utf8
            )
            let loadedExchanges = DotConversationHistoryStore.loadPersistedExchanges()
            #expect(loadedExchanges.isEmpty)
        }
    }

    @Test func loadReturnsEmptyArrayOnValidJsonOfWrongShape() {
        Self.withFreshHistoryFile {
            try? "{\"this_is_not_an_array\":true}".write(
                to: DotConversationHistoryStore.onDiskHistoryFileURL,
                atomically: true,
                encoding: .utf8
            )
            let loadedExchanges = DotConversationHistoryStore.loadPersistedExchanges()
            #expect(loadedExchanges.isEmpty)
        }
    }

    // MARK: - persistExchanges + roundtrip

    @Test func persistThenLoadRoundTripsSingleExchange() {
        Self.withFreshHistoryFile {
            let exchanges = [Self.makeExchange("hello dot", "hi mark")]
            DotConversationHistoryStore.persistExchanges(exchanges)
            let loadedExchanges = DotConversationHistoryStore.loadPersistedExchanges()
            #expect(loadedExchanges.count == 1)
            #expect(loadedExchanges.first?.userTranscript == "hello dot")
            #expect(loadedExchanges.first?.assistantResponse == "hi mark")
        }
    }

    @Test func persistThenLoadRoundTripsMultipleExchanges() {
        Self.withFreshHistoryFile {
            let exchanges = [
                Self.makeExchange("first user msg", "first dot reply"),
                Self.makeExchange("second user msg", "second dot reply"),
                Self.makeExchange("third user msg", "third dot reply")
            ]
            DotConversationHistoryStore.persistExchanges(exchanges)
            let loadedExchanges = DotConversationHistoryStore.loadPersistedExchanges()
            #expect(loadedExchanges.count == 3)
            #expect(loadedExchanges[0].userTranscript == "first user msg")
            #expect(loadedExchanges[1].assistantResponse == "second dot reply")
            #expect(loadedExchanges[2].userTranscript == "third user msg")
        }
    }

    @Test func persistOverwritesPreviousFile() {
        Self.withFreshHistoryFile {
            DotConversationHistoryStore.persistExchanges([
                Self.makeExchange("old A", "old B")
            ])
            DotConversationHistoryStore.persistExchanges([
                Self.makeExchange("new A", "new B")
            ])
            let loadedExchanges = DotConversationHistoryStore.loadPersistedExchanges()
            #expect(loadedExchanges.count == 1)
            #expect(loadedExchanges.first?.userTranscript == "new A")
        }
    }

    @Test func persistEmptyArrayRoundTripsAsEmpty() {
        Self.withFreshHistoryFile {
            DotConversationHistoryStore.persistExchanges([])
            let loadedExchanges = DotConversationHistoryStore.loadPersistedExchanges()
            #expect(loadedExchanges.isEmpty)
        }
    }

    @Test func persistAutoCreatesParentDirectory() {
        Self.withFreshHistoryFile {
            // Override the file URL to live two directories deep so the
            // persist call has to create both intermediate dirs to succeed.
            let savedURL = DotConversationHistoryStore.onDiskHistoryFileURL
            DotConversationHistoryStore.onDiskHistoryFileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("DotHistoryNestedTest-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("nested", isDirectory: true)
                .appendingPathComponent("history.json", isDirectory: false)
            defer {
                let parentToCleanUp = DotConversationHistoryStore.onDiskHistoryFileURL
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                try? FileManager.default.removeItem(at: parentToCleanUp)
                DotConversationHistoryStore.onDiskHistoryFileURL = savedURL
            }

            DotConversationHistoryStore.persistExchanges([Self.makeExchange("x", "y")])
            #expect(FileManager.default.fileExists(atPath: DotConversationHistoryStore.onDiskHistoryFileURL.path))
        }
    }

    // MARK: - clearPersistedHistory

    @Test func clearRemovesPersistedFile() {
        Self.withFreshHistoryFile {
            DotConversationHistoryStore.persistExchanges([Self.makeExchange("a", "b")])
            #expect(FileManager.default.fileExists(atPath: DotConversationHistoryStore.onDiskHistoryFileURL.path))
            DotConversationHistoryStore.clearPersistedHistory()
            #expect(!FileManager.default.fileExists(atPath: DotConversationHistoryStore.onDiskHistoryFileURL.path))
        }
    }

    @Test func clearOnMissingFileIsNoOp() {
        Self.withFreshHistoryFile {
            // File doesn't exist yet — clear must not crash.
            DotConversationHistoryStore.clearPersistedHistory()
            #expect(!FileManager.default.fileExists(atPath: DotConversationHistoryStore.onDiskHistoryFileURL.path))
        }
    }

    // MARK: - Edge cases on the data itself

    @Test func roundTripsUnicodeAndNewlinesInTranscript() {
        Self.withFreshHistoryFile {
            let trickyTranscript = "I 💜 swift\nline two\ttabbed\n\"quoted\""
            let trickyResponse = "got it — 你好世界\nmultiline reply"
            DotConversationHistoryStore.persistExchanges([
                Self.makeExchange(trickyTranscript, trickyResponse)
            ])
            let loadedExchanges = DotConversationHistoryStore.loadPersistedExchanges()
            #expect(loadedExchanges.first?.userTranscript == trickyTranscript)
            #expect(loadedExchanges.first?.assistantResponse == trickyResponse)
        }
    }

    @Test func roundTripsRecordedAtPrecisionWithinOneSecond() {
        Self.withFreshHistoryFile {
            let originalTimestamp = Date()
            let exchange = ConversationExchange(
                userTranscript: "x",
                assistantResponse: "y",
                recordedAt: originalTimestamp
            )
            DotConversationHistoryStore.persistExchanges([exchange])
            let loadedExchanges = DotConversationHistoryStore.loadPersistedExchanges()
            // ISO8601 default precision is to the second — allow up to 1s drift.
            let timestampDriftSeconds = abs(
                (loadedExchanges.first?.recordedAt ?? Date.distantPast)
                    .timeIntervalSince(originalTimestamp)
            )
            #expect(timestampDriftSeconds < 1.0)
        }
    }

    @Test func roundTripsLargeHistoryOfFiftyEntries() {
        Self.withFreshHistoryFile {
            let exchanges = (0..<50).map { exchangeIndex in
                Self.makeExchange("user-\(exchangeIndex)", "dot-\(exchangeIndex)")
            }
            DotConversationHistoryStore.persistExchanges(exchanges)
            let loadedExchanges = DotConversationHistoryStore.loadPersistedExchanges()
            #expect(loadedExchanges.count == 50)
            #expect(loadedExchanges.first?.userTranscript == "user-0")
            #expect(loadedExchanges.last?.assistantResponse == "dot-49")
        }
    }
}
