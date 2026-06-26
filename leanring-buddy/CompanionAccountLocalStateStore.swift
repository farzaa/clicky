//
//  CompanionAccountLocalStateStore.swift
//  leanring-buddy
//
//  Local account UI flags only. Session tokens stay in Keychain-backed
//  SpiderSessionStore; emails are never persisted here.
//

import Foundation

enum CompanionAccountLocalStateStore {
    private static let hasSubmittedEmailKey = "hasSubmittedEmail"
    private static let pendingSpiderEmailKey = "pendingSpiderEmail"

    static func loadHasSubmittedEmail(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: hasSubmittedEmailKey)
    }

    static func persistHasSubmittedEmail(
        _ hasSubmittedEmail: Bool,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(hasSubmittedEmail, forKey: hasSubmittedEmailKey)
    }

    static func clearPendingEmail(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: pendingSpiderEmailKey)
    }
}
