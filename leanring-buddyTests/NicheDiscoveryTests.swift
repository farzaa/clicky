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

    @Test func nicheClauseIncludedInVoicePromptWithoutBreakingSkills() {
        let skill = TeachingSkill(
            id: "teach-test",
            name: "Test Skill",
            description: "Test",
            bundleIds: [],
            status: .active,
            lastUsed: Date(),
            usageCount: 1,
            isPinned: false,
            body: "step one"
        )
        let manager = NicheDiscoveryManager()
        let prompt = TeachingPromptBuilder.buildVoiceResponsePrompt(
            basePrompt: "base",
            matchedSkills: [skill],
            nicheClause: manager.voiceSystemPromptClause(for: .developer)
        )
        #expect(prompt.contains("base"))
        #expect(prompt.contains("the user is a developer"))
        #expect(prompt.contains("teaching skills:"))
        #expect(prompt.contains("step one"))
    }
}
