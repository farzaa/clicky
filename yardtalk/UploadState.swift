//
//  UploadState.swift
//  yardtalk
//
//  Tracks where a session is in the NU upload lifecycle. Stored on
//  YardTalkSession alongside (and orthogonal to) the synthesis status —
//  a session can be `.synthesized` and any of these upload states.
//
//  `idempotencyKey` is generated lazily on the first upload attempt and
//  retained across retries so NU dedupes correctly when a queued or
//  failed upload is re-tried from the outbox (M6). Generating eagerly
//  at session creation would force a migration of every existing
//  session JSON; lazy + persist achieves the same retry-stable
//  semantics with no migration churn.
//

import Foundation

struct UploadState: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case notUploaded
        case queued
        case uploading
        case uploaded
        case failed
    }

    var kind: Kind
    /// Set on the first upload attempt; reused for all subsequent
    /// retries so NU's idempotency contract holds.
    var idempotencyKey: UUID?
    var uploadedAt: Date?
    var errorMessage: String?

    init(
        kind: Kind = .notUploaded,
        idempotencyKey: UUID? = nil,
        uploadedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.kind = kind
        self.idempotencyKey = idempotencyKey
        self.uploadedAt = uploadedAt
        self.errorMessage = errorMessage
    }

    static let notUploaded = UploadState(kind: .notUploaded)
}
