//
//  SessionStore.swift
//  yardtalk
//
//  Per-project session metadata persisted as one JSON-per-session under
//  <project.location>/sessions/. Mirrors ClipStore's shape: in-memory
//  list tracks the active project's sessions only, reload happens via
//  setActiveProject.
//
//  Path resolution uses a location registry: callers register each
//  project's location via registerLocation(_:for:).
//

import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class SessionStore {
    /// Sessions for the currently-active project, sorted newest-first by
    /// `startedAt`. The open session (if any) is always at index 0 because
    /// no session can start in the past.
    private(set) var sessionsForActiveProject: [YardTalkSession] = []

    @ObservationIgnored
    private var activeProjectID: UUID?

    @ObservationIgnored
    private var locationsByProject: [UUID: URL] = [:]

    func registerLocation(_ location: URL, for projectID: UUID) {
        locationsByProject[projectID] = location
    }

    func unregisterLocation(for projectID: UUID) {
        locationsByProject.removeValue(forKey: projectID)
    }

    /// Switches the in-memory list to the given project's sessions. `nil`
    /// clears the list. The project's location must already be registered.
    func setActiveProject(_ projectID: UUID?) {
        activeProjectID = projectID
        loadSessionsForActive()
    }

    /// Persists a new session and prepends it to the list if it belongs to
    /// the active project. Caller is responsible for ensuring no other
    /// session is `.open` for the same project.
    func add(_ session: YardTalkSession) throws {
        try ensureSessionsDirectory(for: session.projectID)
        try save(session)
        if session.projectID == activeProjectID {
            sessionsForActiveProject.insert(session, at: 0)
        }
    }

    /// Updates an existing session's metadata (clipIDs, endedAt, status).
    func update(_ session: YardTalkSession) throws {
        try save(session)
        if session.projectID == activeProjectID,
           let idx = sessionsForActiveProject.firstIndex(where: { $0.id == session.id }) {
            sessionsForActiveProject[idx] = session
        }
    }

    func delete(_ session: YardTalkSession) {
        if let url = metadataFileURL(for: session) { try? FileManager.default.removeItem(at: url) }
        if session.projectID == activeProjectID {
            sessionsForActiveProject.removeAll(where: { $0.id == session.id })
        }
    }

    /// Removes the entire sessions directory for a project.
    func deleteAllSessions(for projectID: UUID) {
        if let dir = sessionsDirectory(for: projectID) {
            try? FileManager.default.removeItem(at: dir)
        }
        if projectID == activeProjectID {
            sessionsForActiveProject = []
        }
    }

    /// Open session for the active project, if any.
    func openSessionForActiveProject() -> YardTalkSession? {
        sessionsForActiveProject.first(where: { $0.status == .open })
    }

    func session(id: UUID) -> YardTalkSession? {
        sessionsForActiveProject.first(where: { $0.id == id })
    }

    /// Scans all registered project locations for sessions with queued
    /// or failed upload state. Returns newest-first.
    func allOutboxSessions() -> [YardTalkSession] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var results: [YardTalkSession] = []

        for (projectID, _) in locationsByProject {
            guard let dir = sessionsDirectory(for: projectID) else { continue }
            guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in urls where url.pathExtension == "json" {
                guard let data = try? EncryptedStore.read(from: url),
                      let session = try? decoder.decode(YardTalkSession.self, from: data),
                      session.uploadState.kind == .queued || session.uploadState.kind == .failed else { continue }
                results.append(session)
            }
        }
        return results.sorted(by: { $0.startedAt > $1.startedAt })
    }

    // MARK: - URLs

    func sessionsDirectory(for projectID: UUID) -> URL? {
        guard let location = locationsByProject[projectID] else { return nil }
        return location.appendingPathComponent("sessions", isDirectory: true)
    }

    // MARK: - Private

    private func ensureSessionsDirectory(for projectID: UUID) throws {
        guard let dir = sessionsDirectory(for: projectID) else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func metadataFileURL(for session: YardTalkSession) -> URL? {
        sessionsDirectory(for: session.projectID)?
            .appendingPathComponent("\(session.id.uuidString).json")
    }

    private func save(_ session: YardTalkSession) throws {
        guard let url = metadataFileURL(for: session) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)
        try EncryptedStore.write(data, to: url)
    }

    private func loadSessionsForActive() {
        guard let projectID = activeProjectID,
              let dir = sessionsDirectory(for: projectID) else {
            sessionsForActiveProject = []
            return
        }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else {
            sessionsForActiveProject = []
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var loaded: [YardTalkSession] = []
        var needsMigration: [YardTalkSession] = []
        for url in urls where url.pathExtension == "json" {
            do {
                let data = try EncryptedStore.read(from: url)
                let session = try decoder.decode(YardTalkSession.self, from: data)
                loaded.append(session)
                if !Self.isEncryptedOnDisk(url) {
                    needsMigration.append(session)
                }
            } catch {
                Logger.session.warning("skipping unreadable session at \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .private)")
            }
        }
        sessionsForActiveProject = loaded.sorted(by: { $0.startedAt > $1.startedAt })
        for session in needsMigration {
            try? save(session)
        }
    }

    /// See ClipStore.isEncryptedOnDisk — same pattern, used to
    /// schedule one-shot re-encryption of pre-migration files.
    private static func isEncryptedOnDisk(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 4) else { return false }
        return prefix == Data("YT01".utf8)
    }
}
