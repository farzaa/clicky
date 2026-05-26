//
//  YardTalkSession.swift
//  yardtalk
//
//  A work block grouping one or more clips recorded back-to-back into a
//  single unit for review and synthesis. Sessions are created lazily on
//  the first hotkey press when no session is already open and ended
//  either by the user explicitly ("End Session" in the panel) or by the
//  idle timeout in SessionManager. There is at most one open session
//  per project by construction.
//
//  Persisted as one-JSON-per-session under
//  <project.location>/sessions/<sessionID>.json.
//
//  `clipIDs` is the canonical ordering of the session's clips and the
//  clip's `sessionID` is the back-reference. Both are kept in sync by
//  SessionManager whenever a clip finalizes; downstream views can pick
//  whichever is cheaper for the access pattern.
//
//  `synthesisResult` and `synthesisError` are populated by M2 once the
//  user (or the auto-trigger) runs end-of-session synthesis through
//  `SynthesisService`. Both are optional — pre-M2 sessions on disk
//  decode with both nil via the custom decoder below.
//

import Foundation

struct YardTalkSession: Codable, Identifiable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        /// Currently accepting new clips. At most one open session per project.
        case open
        /// Closed; no further clips attach. Eligible for synthesis (M2).
        case ended
        /// Synthesis (M2) has produced a structured payload for this session.
        case synthesized
    }

    let id: UUID
    let projectID: UUID
    let startedAt: Date
    var endedAt: Date?
    var clipIDs: [UUID]
    var status: Status
    /// Most recent successful synthesis output. Mutated by M3's
    /// review/edit dialog before upload.
    var synthesisResult: NUSessionPayload?
    /// Last synthesis attempt's failure message, surfaced in the
    /// timeline UI so the user can retry. Cleared when a subsequent
    /// attempt succeeds.
    var synthesisError: String?
    /// Where the session is in the NU upload lifecycle. M2-era
    /// sessions on disk decode with `.notUploaded` via the custom
    /// decoder.
    var uploadState: UploadState

    init(
        id: UUID = UUID(),
        projectID: UUID,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        clipIDs: [UUID] = [],
        status: Status = .open,
        synthesisResult: NUSessionPayload? = nil,
        synthesisError: String? = nil,
        uploadState: UploadState = .notUploaded
    ) {
        self.id = id
        self.projectID = projectID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.clipIDs = clipIDs
        self.status = status
        self.synthesisResult = synthesisResult
        self.synthesisError = synthesisError
        self.uploadState = uploadState
    }

    // Custom decoder so legacy session JSONs (no `synthesisResult`,
    // no `synthesisError`, no `uploadState`) still load. The
    // synthesized init(from:) would throw keyNotFound otherwise.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.projectID = try c.decode(UUID.self, forKey: .projectID)
        self.startedAt = try c.decode(Date.self, forKey: .startedAt)
        self.endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        self.clipIDs = try c.decode([UUID].self, forKey: .clipIDs)
        self.status = try c.decode(Status.self, forKey: .status)
        self.synthesisResult = try c.decodeIfPresent(NUSessionPayload.self, forKey: .synthesisResult)
        self.synthesisError = try c.decodeIfPresent(String.self, forKey: .synthesisError)
        self.uploadState = try c.decodeIfPresent(UploadState.self, forKey: .uploadState) ?? .notUploaded
    }
}
