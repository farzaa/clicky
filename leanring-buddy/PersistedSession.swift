//
//  PersistedSession.swift
//  leanring-buddy
//
//  On-disk session JSON written by SessionStore under ~/.clicky/sessions/.
//

import Foundation

struct PersistedSession: Codable, Equatable {
    let sessionId: UUID
    let startedAt: Date
    let endedAt: Date
    let outcome: SessionOutcome
    let privacyOptOut: Bool
    let appsUsed: [String]
    let turns: [SessionTraceEntry]
}

enum SessionOutcome: String, Codable {
    case success
    case abandoned
    case unknown
}
