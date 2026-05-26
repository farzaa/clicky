//
//  YardTalkProject.swift
//  yardtalk
//
//  Per-project metadata persisted to disk and used as the unit of work for
//  YardTalk sessions. The `name` and `type.rawValue` round-trip into the NU
//  payload as `project` and `project_type` per the frozen contract in
//  CLAUDE.md, so changes to those field names break NU compatibility.
//

import Foundation

struct YardTalkProject: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var type: YardTalkProjectType
    var projectDescription: String
    /// User-chosen directory where clips and sessions are stored.
    /// Projects created before this field existed default to the legacy
    /// App Support path so existing recordings remain discoverable.
    var location: URL
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        type: YardTalkProjectType,
        projectDescription: String = "",
        location: URL,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.projectDescription = projectDescription
        self.location = location
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, type, projectDescription, location, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.type = try c.decode(YardTalkProjectType.self, forKey: .type)
        self.projectDescription = try c.decodeIfPresent(String.self, forKey: .projectDescription) ?? ""
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        if let loc = try c.decodeIfPresent(URL.self, forKey: .location) {
            self.location = loc
        } else {
            self.location = Self.legacyLocation(for: self.id)
        }
    }

    /// Path where clips/sessions lived before the per-project location
    /// field was added. Used as the default when loading old project JSONs.
    static func legacyLocation(for projectID: UUID) -> URL {
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("YardTalk", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
    }
}

/// Project templates supported in v1. Raw values match the NU payload's
/// `project_type` field exactly — see CLAUDE.md. `pen_test_report` is
/// intentionally deferred per the project plan: validate the loop on
/// lower-stakes templates first.
enum YardTalkProjectType: String, Codable, CaseIterable, Sendable {
    case presentationPrep = "presentation_prep"
    case researchNotes = "research_notes"

    var displayName: String {
        switch self {
        case .presentationPrep: return "Presentation Prep"
        case .researchNotes: return "Research Notes"
        }
    }

    var synthesisDescription: String {
        switch self {
        case .presentationPrep: return "Outline, talking points, weak spots"
        case .researchNotes: return "Annotated reading notes grouped by theme"
        }
    }
}
