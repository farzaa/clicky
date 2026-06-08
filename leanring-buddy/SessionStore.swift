//
//  SessionStore.swift
//  leanring-buddy
//
//  Filesystem store for persisted voice sessions under ClickyPaths.sessions.
//

import Foundation

final class SessionStore {
    static var sessionsRootURL: URL {
        ClickyPaths.sessions
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private let dayFolderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    @discardableResult
    func save(_ session: PersistedSession) throws -> URL {
        let fileManager = FileManager.default
        let dayFolderName = dayFolderFormatter.string(from: session.startedAt)
        let dayFolderURL = Self.sessionsRootURL
            .appendingPathComponent(dayFolderName, isDirectory: true)
        try fileManager.createDirectory(at: dayFolderURL, withIntermediateDirectories: true)

        let sessionFileURL = dayFolderURL
            .appendingPathComponent("\(session.sessionId.uuidString).json")
        let encodedData = try encoder.encode(session)
        try encodedData.write(to: sessionFileURL, options: .atomic)
        return sessionFileURL
    }

    func loadAllSessions() -> [PersistedSession] {
        let fileManager = FileManager.default
        guard let dayFolders = try? fileManager.contentsOfDirectory(
            at: Self.sessionsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var loadedSessions: [PersistedSession] = []
        for dayFolder in dayFolders where (try? dayFolder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            guard let sessionFiles = try? fileManager.contentsOfDirectory(
                at: dayFolder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for sessionFile in sessionFiles where sessionFile.pathExtension == "json" {
                guard let fileData = try? Data(contentsOf: sessionFile),
                      let session = try? decoder.decode(PersistedSession.self, from: fileData) else {
                    continue
                }
                loadedSessions.append(session)
            }
        }

        return loadedSessions.sorted { $0.startedAt < $1.startedAt }
    }

    func deleteSessionsOlderThan(days: Int, now: Date = Date()) {
        let fileManager = FileManager.default
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? now

        guard let dayFolders = try? fileManager.contentsOfDirectory(
            at: Self.sessionsRootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for dayFolder in dayFolders {
            let resourceValues = try? dayFolder.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard resourceValues?.isDirectory == true else { continue }

            let folderDate = dayFolderFormatter.date(from: dayFolder.lastPathComponent)
                ?? resourceValues?.contentModificationDate
                ?? .distantPast

            guard folderDate < cutoffDate else { continue }

            try? fileManager.removeItem(at: dayFolder)
        }
    }
}
