//
//  SessionStoreTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import leanring_buddy

@Suite(.serialized)
struct SessionStoreTests {
    private func makeTemporaryHome() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-session-test-\(UUID().uuidString)", isDirectory: true)
    }

    private func dayFolderFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private func sampleSession(
        sessionId: UUID = UUID(),
        startedAt: Date = Date(timeIntervalSince1970: 1_747_000_000),
        endedAt: Date = Date(timeIntervalSince1970: 1_747_000_120)
    ) -> PersistedSession {
        PersistedSession(
            sessionId: sessionId,
            startedAt: startedAt,
            endedAt: endedAt,
            outcome: .success,
            privacyOptOut: false,
            appsUsed: ["com.apple.TextEdit", "com.apple.Safari"],
            turns: [
                SessionTraceEntry(
                    timestamp: startedAt,
                    userTranscript: "how do i save in textedit?",
                    assistantResponse: "press command-s to save.",
                    bundleId: "com.apple.TextEdit",
                    pointed: true
                ),
                SessionTraceEntry(
                    timestamp: endedAt,
                    userTranscript: "got it",
                    assistantResponse: "nice.",
                    bundleId: "com.apple.TextEdit",
                    pointed: false
                )
            ]
        )
    }

    @Test func sessionStoreRoundTripPreservesAllFields() throws {
        let temporaryHome = makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: temporaryHome) }

        try ClickyTestHomeIsolation.withIsolatedHome(temporaryHome) {
            try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true)

            let session = sampleSession()
            let store = SessionStore()
            let savedURL = try store.save(session)

            let fileData = try Data(contentsOf: savedURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decodedSession = try decoder.decode(PersistedSession.self, from: fileData)

            #expect(decodedSession == session)
            #expect(store.loadAllSessions() == [session])
        }
    }

    @Test func sessionStoreWritesExpectedPathShape() throws {
        let temporaryHome = makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: temporaryHome) }

        try ClickyTestHomeIsolation.withIsolatedHome(temporaryHome) {
            try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true)

            let sessionId = UUID()
            let startedAt = Date(timeIntervalSince1970: 1_747_000_000)
            let session = sampleSession(sessionId: sessionId, startedAt: startedAt)
            let store = SessionStore()
            let savedURL = try store.save(session)

            let expectedDayFolder = dayFolderFormatter().string(from: startedAt)
            let expectedURL = temporaryHome
                .appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent(expectedDayFolder, isDirectory: true)
                .appendingPathComponent("\(sessionId.uuidString).json")

            #expect(savedURL == expectedURL)
            #expect(FileManager.default.fileExists(atPath: expectedURL.path))
        }
    }

    @Test func sessionStoreWritesISO8601DatesAndStringOutcome() throws {
        let temporaryHome = makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: temporaryHome) }

        try ClickyTestHomeIsolation.withIsolatedHome(temporaryHome) {
            try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true)

            let session = sampleSession()
            let store = SessionStore()
            let savedURL = try store.save(session)

            let jsonObject = try JSONSerialization.jsonObject(with: Data(contentsOf: savedURL)) as? [String: Any]
            #expect(jsonObject != nil)
            #expect(jsonObject?["outcome"] as? String == "success")
            #expect(jsonObject?["startedAt"] is String)
            #expect(jsonObject?["endedAt"] is String)
            #expect((jsonObject?["startedAt"] as? String)?.contains("T") == true)
        }
    }

    @Test func sessionStoreDeletesSessionsOlderThanSevenDays() throws {
        let temporaryHome = makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: temporaryHome) }

        try ClickyTestHomeIsolation.withIsolatedHome(temporaryHome) {
            try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true)

            let formatter = dayFolderFormatter()
            let now = Date()
            let eightDaysAgo = Calendar.current.date(byAdding: .day, value: -8, to: now)!
            let oldDayFolder = ClickyPaths.sessions.appendingPathComponent(formatter.string(from: eightDaysAgo), isDirectory: true)
            let todayFolder = ClickyPaths.sessions.appendingPathComponent(formatter.string(from: now), isDirectory: true)

            try FileManager.default.createDirectory(at: oldDayFolder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: todayFolder, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: oldDayFolder.appendingPathComponent("old.json"))
            try Data("{}".utf8).write(to: todayFolder.appendingPathComponent("recent.json"))

            SessionStore().deleteSessionsOlderThan(days: 7, now: now)

            #expect(FileManager.default.fileExists(atPath: oldDayFolder.path) == false)
            #expect(FileManager.default.fileExists(atPath: todayFolder.path))
        }
    }

    @Test func sessionTraceEntryIsCodable() throws {
        let entry = SessionTraceEntry(
            timestamp: Date(timeIntervalSince1970: 1_747_000_000),
            userTranscript: "hello",
            assistantResponse: "hi",
            bundleId: "com.apple.TextEdit",
            pointed: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let encodedData = try encoder.encode(entry)
        let decodedEntry = try decoder.decode(SessionTraceEntry.self, from: encodedData)

        #expect(decodedEntry == entry)
    }
}
