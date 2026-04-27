//
//  ClipStore.swift
//  yardtalk
//
//  Per-project clip metadata persisted as one JSON-per-clip alongside the
//  MP4 at ~/Library/Application Support/YardTalk/projects/<projectID>/
//  clips/<clipID>.{mp4,json}. The in-memory list tracks only the active
//  project's clips — call setActiveProject when the active project changes
//  and the store reloads from disk.
//

import Foundation
import Observation

@MainActor
@Observable
final class ClipStore {
    private(set) var clipsForActiveProject: [YardTalkClip] = []

    @ObservationIgnored
    private let projectsRoot: URL

    @ObservationIgnored
    private var activeProjectID: UUID?

    init(projectsRoot: URL? = nil) {
        self.projectsRoot = projectsRoot ?? Self.defaultProjectsRoot()
    }

    /// Switches the in-memory list to the given project's clips. `nil`
    /// clears the list. Loading is synchronous because clip metadata is
    /// small and the user just made the active selection — they expect
    /// the list to populate immediately.
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
        try? FileManager.default.removeItem(at: videoFileURL(for: clip))
        try? FileManager.default.removeItem(at: metadataFileURL(for: clip))
        if clip.projectID == activeProjectID {
            clipsForActiveProject.removeAll(where: { $0.id == clip.id })
        }
    }

    /// Removes the entire clips directory for a project — called when the
    /// project itself is deleted.
    func deleteAllClips(for projectID: UUID) {
        try? FileManager.default.removeItem(at: projectDirectory(for: projectID))
        if projectID == activeProjectID {
            clipsForActiveProject = []
        }
    }

    // MARK: - URLs

    func clipsDirectory(for projectID: UUID) -> URL {
        projectDirectory(for: projectID).appendingPathComponent("clips", isDirectory: true)
    }

    func videoFileURL(for clip: YardTalkClip) -> URL {
        clipsDirectory(for: clip.projectID).appendingPathComponent(clip.fileName)
    }

    // MARK: - Private

    private static func defaultProjectsRoot() -> URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("YardTalk", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    private func projectDirectory(for projectID: UUID) -> URL {
        projectsRoot.appendingPathComponent(projectID.uuidString, isDirectory: true)
    }

    private func ensureClipsDirectory(for projectID: UUID) throws {
        try FileManager.default.createDirectory(
            at: clipsDirectory(for: projectID),
            withIntermediateDirectories: true
        )
    }

    private func metadataFileURL(for clip: YardTalkClip) -> URL {
        clipsDirectory(for: clip.projectID)
            .appendingPathComponent("\(clip.id.uuidString).json")
    }

    private func save(_ clip: YardTalkClip) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(clip)
        try data.write(to: metadataFileURL(for: clip), options: .atomic)
    }

    private func loadClipsForActive() {
        guard let projectID = activeProjectID else {
            clipsForActiveProject = []
            return
        }
        let dir = clipsDirectory(for: projectID)
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
        for url in urls where url.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: url)
                loaded.append(try decoder.decode(YardTalkClip.self, from: data))
            } catch {
                print("⚠️ YardTalk: skipping unreadable clip at \(url.lastPathComponent): \(error)")
            }
        }
        clipsForActiveProject = loaded.sorted(by: { $0.recordedAt > $1.recordedAt })
    }
}
