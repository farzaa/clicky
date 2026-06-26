//
//  CompanionAccountLocalStateStoreTests.swift
//  leanring-buddyTests
//
//  Tests for non-sensitive local account UI flags.
//

import Foundation
import Testing
@testable import Spider

struct CompanionAccountLocalStateStoreTests {
    @Test func persistsOnlyTheSubmittedEmailFlag() throws {
        let defaults = try isolatedDefaults()

        #expect(CompanionAccountLocalStateStore.loadHasSubmittedEmail(defaults: defaults) == false)

        CompanionAccountLocalStateStore.persistHasSubmittedEmail(true, defaults: defaults)
        #expect(CompanionAccountLocalStateStore.loadHasSubmittedEmail(defaults: defaults) == true)

        CompanionAccountLocalStateStore.persistHasSubmittedEmail(false, defaults: defaults)
        #expect(CompanionAccountLocalStateStore.loadHasSubmittedEmail(defaults: defaults) == false)
    }

    @Test func clearsLegacyPendingEmailWithoutPersistingReplacementEmail() throws {
        let defaults = try isolatedDefaults()
        defaults.set("person@example.test", forKey: "pendingSpiderEmail")

        CompanionAccountLocalStateStore.clearPendingEmail(defaults: defaults)

        #expect(defaults.string(forKey: "pendingSpiderEmail") == nil)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suiteName = "CompanionAccountLocalStateStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
