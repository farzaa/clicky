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
            #expect(suggestions.allSatisfy { !$0.id.isEmpty && !$0.prompt.isEmpty })
        }
    }

    @Test func suggestionSnapshotLimitsToThreeCards() {
        let manager = NicheDiscoveryManager()
        let snapshot = manager.suggestionSnapshot(frontmostBundleId: "com.apple.dt.Xcode")
        #expect(snapshot.suggestions.count == 3)
        #expect(snapshot.mode == .appAware)
        #expect(snapshot.contextLabel.contains("Xcode"))
    }

    @Test func ghosttyUsesAppAwareSuggestionsWithoutManualNiche() {
        let manager = NicheDiscoveryManager()
        let snapshot = manager.suggestionSnapshot(frontmostBundleId: "com.mitchellh.ghostty")
        #expect(snapshot.mode == .appAware)
        #expect(snapshot.suggestions.first?.id == "ghostty-command")
    }

    @Test func persistsUserNicheOverrideAcrossInstances() {
        let userDefaults = UserDefaults(suiteName: "NicheDiscoveryTests")!
        userDefaults.removePersistentDomain(forName: "NicheDiscoveryTests")

        let firstManager = NicheDiscoveryManager(userDefaults: userDefaults)
        firstManager.setUserNiche(.designer)
        #expect(firstManager.userNicheOverride == .designer)

        let secondManager = NicheDiscoveryManager(userDefaults: userDefaults)
        #expect(secondManager.userNicheOverride == .designer)

        userDefaults.removePersistentDomain(forName: "NicheDiscoveryTests")
    }

    @Test func infersDeveloperProfileFromTrackedUsage() {
        let usageFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-niche-tests-\(UUID().uuidString).json")
        let collector = AppUsageCollector(usageFileURL: usageFileURL)
        collector.start()
        collector.recordFrontmostApplicationChange(to: "com.mitchellh.ghostty")
        Thread.sleep(forTimeInterval: 0.05)
        collector.recordFrontmostApplicationChange(to: "com.apple.dt.Xcode")
        Thread.sleep(forTimeInterval: 0.05)
        collector.recordFrontmostApplicationChange(to: nil)

        let classifier = NicheClassifier()
        let result = classifier.classify(
            weightedSecondsByBundleId: collector.weightedSecondsByBundleId()
        )

        #expect(result.primaryNiche == .developer)
        try? FileManager.default.removeItem(at: usageFileURL)
    }

    @Test func neutralSafariUsesGeneralFallbackWithoutStableProfile() {
        let manager = NicheDiscoveryManager()
        let snapshot = manager.suggestionSnapshot(frontmostBundleId: "com.apple.Safari")
        #expect(snapshot.mode == .generalFallback)
    }

    @Test func userNicheOverrideReplacesAppAwareSuggestions() {
        let userDefaults = UserDefaults(suiteName: "NicheDiscoveryTests.override")!
        userDefaults.removePersistentDomain(forName: "NicheDiscoveryTests.override")

        let manager = NicheDiscoveryManager(userDefaults: userDefaults)
        let automaticSnapshot = manager.suggestionSnapshot(frontmostBundleId: "com.mitchellh.ghostty")
        #expect(automaticSnapshot.mode == .appAware)
        #expect(automaticSnapshot.suggestions.first?.id == "ghostty-command")

        manager.setUserNiche(.designer)
        let designerSnapshot = manager.suggestionSnapshot(frontmostBundleId: "com.mitchellh.ghostty")
        #expect(designerSnapshot.mode == .userOverride)
        #expect(!designerSnapshot.suggestions.map(\.id).contains("ghostty-command"))

        manager.setUserNiche(.developer)
        let developerSnapshot = manager.suggestionSnapshot(frontmostBundleId: "com.mitchellh.ghostty")
        #expect(developerSnapshot.mode == .userOverride)
        #expect(developerSnapshot.suggestions.map(\.id) != designerSnapshot.suggestions.map(\.id))

        userDefaults.removePersistentDomain(forName: "NicheDiscoveryTests.override")
    }

    @Test func voicePromptClausePresentForEachNiche() {
        let manager = NicheDiscoveryManager()
        for niche in NicheDiscoveryManager.Niche.allCases {
            let clause = manager.voiceSystemPromptClause(for: niche)
            #expect(!clause.isEmpty)
        }
    }
}
