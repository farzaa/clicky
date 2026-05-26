//
//  ProjectStore.swift
//  yardtalk
//
//  Disk-backed registry of YardTalkProject. Each project is a separate
//  JSON file under ~/Library/Application Support/YardTalk/projects/ so a
//  corrupted save can't take down the whole list. The active project's UUID
//  lives in UserDefaults so it survives restart — that's UI selection state,
//  not project data, and shouldn't sit alongside the JSON files.
//

import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class ProjectStore {
    private(set) var projects: [YardTalkProject] = []
    private(set) var activeProjectID: UUID?

    var activeProject: YardTalkProject? {
        guard let id = activeProjectID else { return nil }
        return projects.first(where: { $0.id == id })
    }

    @ObservationIgnored
    private let projectsDirectory: URL

    @ObservationIgnored
    private let activeProjectKey = "activeProjectID"

    init(projectsDirectory: URL? = nil) {
        self.projectsDirectory = projectsDirectory ?? Self.defaultProjectsDirectory()
        bootstrap()
    }

    /// Creates a new project, persists it, and makes it active. Names are
    /// trimmed; empty names are rejected because they'd round-trip into the NU
    /// payload's `project` field (which is the slug, per the contract).
    @discardableResult
    func createProject(name: String, type: YardTalkProjectType, projectDescription: String = "", location: URL) throws -> YardTalkProject {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw ProjectStoreError.invalidName }

        let project = YardTalkProject(name: trimmedName, type: type, projectDescription: projectDescription, location: location)
        try save(project)
        projects.insert(project, at: 0)
        setActive(project.id)
        return project
    }

    func updateProject(_ project: YardTalkProject) throws {
        try save(project)
        if let idx = projects.firstIndex(where: { $0.id == project.id }) {
            projects[idx] = project
        }
    }

    /// Sets the active project. Pass `nil` to clear the selection (e.g. after
    /// deleting the last project).
    func setActive(_ id: UUID?) {
        activeProjectID = id
        if let id {
            UserDefaults.standard.set(id.uuidString, forKey: activeProjectKey)
        } else {
            UserDefaults.standard.removeObject(forKey: activeProjectKey)
        }
    }

    /// Deletes the project's on-disk file, its clips directory if any, and
    /// removes it from the list. If the deleted project was active, the
    /// next-most-recently-updated one becomes active.
    func delete(id: UUID) throws {
        try FileManager.default.removeItem(at: projectFileURL(for: id))
        // The project's clips directory at projects/<uuid>/ may not exist
        // yet (no clips recorded), so this best-effort remove is fine.
        let projectDir = projectsDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: projectDir)
        projects.removeAll(where: { $0.id == id })
        if activeProjectID == id {
            setActive(projects.first?.id)
        }
    }

    // MARK: - Private

    private static func defaultProjectsDirectory() -> URL {
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

    private func bootstrap() {
        try? FileManager.default.createDirectory(
            at: projectsDirectory,
            withIntermediateDirectories: true
        )
        loadProjects()
        restoreActiveSelection()
    }

    private func loadProjects() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: nil
        ) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var loaded: [YardTalkProject] = []
        var needsMigration: [YardTalkProject] = []
        for url in urls where url.pathExtension == "json" {
            do {
                let data = try EncryptedStore.read(from: url)
                let project = try decoder.decode(YardTalkProject.self, from: data)
                loaded.append(project)
                if !Self.isEncryptedOnDisk(url) {
                    needsMigration.append(project)
                }
            } catch {
                Logger.session.warning("skipping unreadable project at \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .private)")
            }
        }
        projects = loaded.sorted(by: { $0.updatedAt > $1.updatedAt })
        for project in needsMigration {
            try? save(project)
        }
    }

    private static func isEncryptedOnDisk(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 4) else { return false }
        return prefix == Data("YT01".utf8)
    }

    private func restoreActiveSelection() {
        if let stored = UserDefaults.standard.string(forKey: activeProjectKey),
           let id = UUID(uuidString: stored),
           projects.contains(where: { $0.id == id }) {
            activeProjectID = id
        } else {
            activeProjectID = projects.first?.id
        }
    }

    private func save(_ project: YardTalkProject) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)
        try EncryptedStore.write(data, to: projectFileURL(for: project.id))
    }

    private func projectFileURL(for id: UUID) -> URL {
        projectsDirectory.appendingPathComponent("\(id.uuidString).json")
    }
}

enum ProjectStoreError: LocalizedError {
    case invalidName

    var errorDescription: String? {
        switch self {
        case .invalidName: return "Project name cannot be empty."
        }
    }
}
