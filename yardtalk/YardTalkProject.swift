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
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        type: YardTalkProjectType,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
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
