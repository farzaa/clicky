//
//  NUSessionPayload.swift
//  yardtalk
//
//  The frozen payload contract for `POST /api/v1/sessions/` on
//  NeighborhoodUnited (NU). Field names match the contract in CLAUDE.md
//  exactly — renaming any of these breaks NU compatibility per
//  performlikemj/nbhd-united#330.
//
//  AI-generated fields (`summary`, `accomplishments`, `blockers`,
//  `next_steps`) come out of `SynthesisService` via Claude tool-use.
//  Stamped fields (project/session metadata, timestamps, ids) are
//  filled in by the template's `payload(from:context:)`. The payload
//  is mutable on the AI-generated fields so M3's review/edit dialog
//  can rewrite them before upload.
//

import Foundation

struct NUSessionPayload: Codable, Equatable, Sendable {
    let source: String
    let project: String
    let projectType: String
    let sessionStart: Date
    let sessionEnd: Date
    var summary: String
    var accomplishments: [String]
    var blockers: [String]
    var nextSteps: [String]
    let references: References
    let testMode: Bool
    let schemaVersion: Int

    struct References: Codable, Equatable, Sendable {
        /// `nil` until M9 generates a local report file. Optional in JSON
        /// (encoded only when present) so dev payloads aren't littered
        /// with empty strings.
        var reportURL: URL?
        var clipIDs: [String]

        enum CodingKeys: String, CodingKey {
            case reportURL = "report_url"
            case clipIDs = "clip_ids"
        }
    }

    enum CodingKeys: String, CodingKey {
        case source
        case project
        case projectType = "project_type"
        case sessionStart = "session_start"
        case sessionEnd = "session_end"
        case summary
        case accomplishments
        case blockers
        case nextSteps = "next_steps"
        case references
        case testMode = "test_mode"
        case schemaVersion = "schema_version"
    }

    /// Source string sent to NU. Bumped manually when the client
    /// behaviour changes in a way NU should know about.
    static let source = "yardtalk-mac/0.1.0"

    /// Always 1 until the contract changes.
    static let schemaVersion = 1

    /// Debug builds always send `test_mode: true` so dev pushes don't
    /// pollute the real assistant index. Release flips it false.
    /// Locked decision per planning: build-config not session-config.
    static var defaultTestMode: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}
