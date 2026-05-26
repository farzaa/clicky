//
//  ClipStore.swift
//  yardtalk
//
//  Per-project clip metadata persisted as one JSON-per-clip alongside the
//  MP4 under <project.location>/clips/<clipID>.{mp4,json}. The in-memory
//  list tracks only the active project's clips — call setActiveProject when
//  the active project changes and the store reloads from disk.
//
//  Path resolution uses a location registry: callers register each project's
//  location via registerLocation(_:for:) so the store can write to the
//  correct directory for any project, not just the active one. This matters
//  because transcription finishes asynchronously and the user may have
//  switched projects by the time update() is called.
//

import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class ClipStore {
    private(set) var clipsForActiveProject: [YardTalkClip] = []

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

    /// Switches the in-memory list to the given project's clips. `nil`
    /// clears the list. The project's location must already be registered.
    func setActiveProject(_ projectID: UUID?) {
        activeProjectID = projectID
        loadClipsForActive()
    }

    /// Persists a newly-recorded clip and prepends it to the list if it
    /// belongs to the currently-active project. The MP4 must already exist
    /// at the file URL implied by `clip.fileName`.
    func add(_ clip: YardTalkClip) throws {
        try ensureClipsDirectory(for: clip.projectID)
        try save(clip)
        if clip.projectID == activeProjectID {
            clipsForActiveProject.insert(clip, at: 0)
        }
    }

    /// Updates an existing clip's metadata (typically the transcript).
    func update(_ clip: YardTalkClip) throws {
        try save(clip)
        if clip.projectID == activeProjectID,
           let idx = clipsForActiveProject.firstIndex(where: { $0.id == clip.id }) {
            clipsForActiveProject[idx] = clip
        }
    }

    func delete(_ clip: YardTalkClip) {
        if let url = videoFileURL(for: clip) { try? FileManager.default.removeItem(at: url) }
        if let url = metadataFileURL(for: clip) { try? FileManager.default.removeItem(at: url) }
        if clip.projectID == activeProjectID {
            clipsForActiveProject.removeAll(where: { $0.id == clip.id })
        }
    }

    /// Removes the entire clips directory for a project.
    func deleteAllClips(for projectID: UUID) {
        let dir = clipsDirectory(for: projectID)
        if let dir { try? FileManager.default.removeItem(at: dir) }
        if projectID == activeProjectID {
            clipsForActiveProject = []
        }
    }

    // MARK: - URLs

    func clipsDirectory(for projectID: UUID) -> URL? {
        guard let location = locationsByProject[projectID] else { return nil }
        return location.appendingPathComponent("clips", isDirectory: true)
    }

    func videoFileURL(for clip: YardTalkClip) -> URL? {
        clipsDirectory(for: clip.projectID)?
            .appendingPathComponent(clip.fileName)
    }

    // MARK: - Private

    private func ensureClipsDirectory(for projectID: UUID) throws {
        guard let dir = clipsDirectory(for: projectID) else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func metadataFileURL(for clip: YardTalkClip) -> URL? {
        clipsDirectory(for: clip.projectID)?
            .appendingPathComponent("\(clip.id.uuidString).json")
    }

    private func save(_ clip: YardTalkClip) throws {
        guard let url = metadataFileURL(for: clip) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(clip)
        try EncryptedStore.write(data, to: url)
    }

    private func loadClipsForActive() {
        guard let projectID = activeProjectID,
              let dir = clipsDirectory(for: projectID) else {
            clipsForActiveProject = []
            return
        }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else {
            clipsForActiveProject = []
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var loaded: [YardTalkClip] = []
        var needsMigration: [YardTalkClip] = []
        for url in urls where url.pathExtension == "json" {
            do {
                let data = try EncryptedStore.read(from: url)
                let clip = try decoder.decode(YardTalkClip.self, from: data)
                loaded.append(clip)
                // If the file is still plaintext (pre-migration), schedule
                // a re-encrypt by deferring a save until after this loop —
                // we don't want to mutate the directory mid-enumeration.
                if !Self.isEncryptedOnDisk(url) {
                    needsMigration.append(clip)
                }
            } catch {
                Logger.session.warning("skipping unreadable clip at \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .private)")
            }
        }
        clipsForActiveProject = loaded.sorted(by: { $0.recordedAt > $1.recordedAt })
        for clip in needsMigration {
            try? save(clip)
        }
    }

    /// Cheap header check used by the migration sweep — reads the
    /// first 4 bytes and matches against the "YT01" magic written
    /// by `EncryptedStore`.
    private static func isEncryptedOnDisk(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 4) else { return false }
        return prefix == Data("YT01".utf8)
    }
}
