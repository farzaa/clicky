//
//  NicheDiscoveryTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing
@testable import leanring_buddy

struct NicheDiscoveryTests {
    @Test func loadsBundledSuggestionsForEachNiche() throws {
        let manager = NicheDiscoveryManager()

        for niche in NicheDiscoveryManager.Niche.allCases {
            let suggestions = manager.suggestions(for: niche)
            #expect(suggestions.count >= 3, "Expected at least 3 suggestions for \(niche.rawValue)")
            #expect(suggestions.count <= 5, "Expected at most 5 suggestions for \(niche.rawValue)")
            #expect(suggestions.allSatisfy { !$0.id.isEmpty && !$0.prompt.isEmpty })
        }
    }

    @Test func contentCreatorSuggestionsDifferFromDeveloper() {
        let manager = NicheDiscoveryManager()
        let creatorPrompts = Set(manager.suggestions(for: .contentCreator).map(\.prompt))
        let developerPrompts = Set(manager.suggestions(for: .developer).map(\.prompt))
        #expect(creatorPrompts != developerPrompts)
    }

    @Test func persistsSelectedNicheAcrossInstances() {
        let userDefaults = UserDefaults(suiteName: "NicheDiscoveryTests")!
        userDefaults.removePersistentDomain(forName: "NicheDiscoveryTests")

        let firstManager = NicheDiscoveryManager(userDefaults: userDefaults)
        firstManager.setNiche(.designer)
        #expect(firstManager.selectedNiche == .designer)

        let secondManager = NicheDiscoveryManager(userDefaults: userDefaults)
        #expect(secondManager.selectedNiche == .designer)
        #expect(secondManager.suggestionsForCurrentNiche().count >= 3)

        userDefaults.removePersistentDomain(forName: "NicheDiscoveryTests")
    }

    @Test func suggestionsForCurrentNicheEmptyWhenUnset() {
        let userDefaults = UserDefaults(suiteName: "NicheDiscoveryTests.unset")!
        userDefaults.removePersistentDomain(forName: "NicheDiscoveryTests.unset")

        let manager = NicheDiscoveryManager(userDefaults: userDefaults)
        #expect(manager.selectedNiche == nil)
        #expect(manager.suggestionsForCurrentNiche().isEmpty)

        userDefaults.removePersistentDomain(forName: "NicheDiscoveryTests.unset")
    }

    @Test func voicePromptClausePresentForEachNiche() {
        let manager = NicheDiscoveryManager()
        for niche in NicheDiscoveryManager.Niche.allCases {
            let clause = manager.voiceSystemPromptClause(for: niche)
            #expect(!clause.isEmpty)
        }
    }

    @Test func xcodeBundleIdReturnsAppSpecificDeveloperSuggestions() {
        let manager = NicheDiscoveryManager()
        let suggestions = manager.suggestions(
            for: .developer,
            frontmostBundleId: "com.apple.dt.Xcode"
        )
        #expect(!suggestions.isEmpty)
        #expect(suggestions.first?.id == "xcode-source-control")
        #expect(suggestions.allSatisfy { $0.id.hasPrefix("xcode-") })
    }

    @Test func unknownBundleIdFallsBackToBundledDeveloperSuggestions() {
        let manager = NicheDiscoveryManager()
        let bundledSuggestions = manager.suggestions(for: .developer)
        let suggestions = manager.suggestions(
            for: .developer,
            frontmostBundleId: "com.unknown.app"
        )
        #expect(suggestions.map(\.id) == bundledSuggestions.map(\.id))
        #expect(suggestions.first?.id == "commit-changes")
    }

    @Test func contextLabelMentionsXcodeForDeveloperNiche() {
        let manager = NicheDiscoveryManager()
        let label = manager.contextLabel(
            for: .developer,
            frontmostBundleId: "com.apple.dt.Xcode"
        )
        #expect(label?.contains("Xcode") == true)
    }
}
