//
//  NicheDiscoveryManager.swift
//  leanring-buddy
//
//  Orchestrates app usage tracking, niche inference, and suggestion cards.
//

import Foundation

struct NicheSuggestion: Identifiable, Equatable, Codable {
    let id: String
    let prompt: String
}

struct NicheSuggestionsFile: Codable {
    let suggestions: [NicheSuggestion]
}

struct NicheSuggestionSnapshot: Equatable {
    enum Mode: String, Equatable {
        case appAware = "app-aware"
        case usageBased = "usage-based"
        case profileBiased = "profile-biased"
        case userOverride = "user-override"
        case generalFallback = "general-fallback"
    }

    let mode: Mode
    let contextLabel: String
    let suggestions: [NicheSuggestion]
    let effectiveNiche: NicheDiscoveryManager.Niche?
}

@MainActor
final class NicheDiscoveryManager {
    static let selectedUserNicheUserDefaultsKey = "selectedUserNiche"
    static let maximumSuggestionCount = 3

    enum Niche: String, CaseIterable, Identifiable, Codable {
        case contentCreator = "content-creator"
        case developer
        case student
        case designer
        case other

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .contentCreator: return "Creator"
            case .developer: return "Developer"
            case .student: return "Student"
            case .designer: return "Designer"
            case .other: return "General"
            }
        }
    }

    private let bundle: Bundle
    private let userDefaults: UserDefaults
    private let appUsageCollector: AppUsageCollector
    private let nicheClassifier: NicheClassifier
    private var cachedSuggestionsByNiche: [Niche: [NicheSuggestion]] = [:]

    private(set) var inferredNiche: Niche?
    private(set) var profileIsStable = false
    private(set) var profileConfidence: Double = 0

    init(
        bundle: Bundle = .main,
        userDefaults: UserDefaults = .standard,
        appUsageCollector: AppUsageCollector = AppUsageCollector(),
        nicheClassifier: NicheClassifier = NicheClassifier()
    ) {
        self.bundle = bundle
        self.userDefaults = userDefaults
        self.appUsageCollector = appUsageCollector
        self.nicheClassifier = nicheClassifier
    }

    var userNicheOverride: Niche? {
        guard let rawValue = userDefaults.string(forKey: Self.selectedUserNicheUserDefaultsKey) else {
            return nil
        }
        return Niche(rawValue: rawValue)
    }

    var effectiveNiche: Niche? {
        userNicheOverride ?? inferredNiche
    }

    func startTracking() {
        appUsageCollector.start()
        refreshInferredProfile()
    }

    func stopTracking() {
        appUsageCollector.stop()
    }

    func setUserNicheOverride(_ niche: Niche?) {
        if let niche {
            userDefaults.set(niche.rawValue, forKey: Self.selectedUserNicheUserDefaultsKey)
        } else {
            userDefaults.removeObject(forKey: Self.selectedUserNicheUserDefaultsKey)
        }
    }

    func setUserNiche(_ niche: Niche) {
        setUserNicheOverride(niche)
    }

    func clearUserNicheOverride() {
        setUserNicheOverride(nil)
    }

    func handleFrontmostApplicationChanged(to bundleId: String?) {
        appUsageCollector.recordFrontmostApplicationChange(to: bundleId)
        refreshInferredProfile()
    }

    func refreshInferredProfile() {
        let classification = nicheClassifier.classify(
            weightedSecondsByBundleId: appUsageCollector.weightedSecondsByBundleId()
        )
        inferredNiche = classification.primaryNiche
        profileIsStable = classification.profileIsStable
        profileConfidence = classification.confidence
    }

    func suggestionSnapshot(frontmostBundleId: String?) -> NicheSuggestionSnapshot {
        let usageByBundleId = appUsageCollector.weightedSecondsByBundleId()
        let isExplicitNicheOverride = userNicheOverride != nil
        let bundleIdForSuggestions = frontmostBundleIdForSuggestions(systemFrontmostBundleId: frontmostBundleId)

        guard let nicheForSuggestions = resolvedNicheForSuggestions() else {
            return NicheSuggestionSnapshot(
                mode: .generalFallback,
                contextLabel: "Pick your niche below — suggestions will match the apps you use:",
                suggestions: [],
                effectiveNiche: inferredNiche
            )
        }

        if let bundleIdForSuggestions,
           nicheClassifier.appMatchesNiche(bundleId: bundleIdForSuggestions, niche: nicheForSuggestions),
           let appSpecificSuggestions = NicheAppSuggestionMapping.appSpecificSuggestions(bundleId: bundleIdForSuggestions),
           let contextLabel = NicheAppSuggestionMapping.contextLabel(bundleId: bundleIdForSuggestions) {
            return NicheSuggestionSnapshot(
                mode: isExplicitNicheOverride ? .userOverride : .appAware,
                contextLabel: contextLabel,
                suggestions: limitedSuggestions(appSpecificSuggestions),
                effectiveNiche: nicheForSuggestions
            )
        }

        let minimumTrackedSecondsForRanking = isExplicitNicheOverride
            ? NicheClassifier.minimumTrackedSecondsForExplicitNicheAppRanking
            : NicheClassifier.minimumTrackedSecondsForAppRanking

        let rankedMatchingBundleIds = nicheClassifier.rankedBundleIdsMatchingNiche(
            niche: nicheForSuggestions,
            weightedSecondsByBundleId: usageByBundleId,
            minimumTrackedSeconds: minimumTrackedSecondsForRanking
        )

        for rankedBundleId in rankedMatchingBundleIds {
            guard let appSpecificSuggestions = NicheAppSuggestionMapping.appSpecificSuggestions(bundleId: rankedBundleId),
                  let appDisplayName = NicheAppSuggestionMapping.appDisplayName(bundleId: rankedBundleId) else {
                continue
            }

            return NicheSuggestionSnapshot(
                mode: isExplicitNicheOverride ? .userOverride : .usageBased,
                contextLabel: "From the \(nicheForSuggestions.displayName.lowercased()) apps you use — try in \(appDisplayName):",
                suggestions: limitedSuggestions(appSpecificSuggestions),
                effectiveNiche: nicheForSuggestions
            )
        }

        return NicheSuggestionSnapshot(
            mode: isExplicitNicheOverride ? .userOverride : (profileIsStable ? .profileBiased : .generalFallback),
            contextLabel: noMatchingAppsContextLabel(for: nicheForSuggestions),
            suggestions: [],
            effectiveNiche: nicheForSuggestions
        )
    }

    private func noMatchingAppsContextLabel(for niche: Niche) -> String {
        "Open a \(niche.displayName.lowercased()) app you use — suggestions will match what's on screen:"
    }

    private func frontmostBundleIdForSuggestions(systemFrontmostBundleId: String?) -> String? {
        let clickyBundleId = bundle.bundleIdentifier
        var excludedBundleIds = Set<String>()
        if let clickyBundleId {
            excludedBundleIds.insert(clickyBundleId)
        }

        if let systemFrontmostBundleId,
           !excludedBundleIds.contains(systemFrontmostBundleId),
           !nicheClassifier.isNeutralApp(bundleId: systemFrontmostBundleId) {
            return systemFrontmostBundleId
        }

        return appUsageCollector.mostRecentlyUsedBundleId(excludingBundleIds: excludedBundleIds)
    }

    private func resolvedNicheForSuggestions() -> Niche? {
        if let userNicheOverride {
            return userNicheOverride
        }

        if profileIsStable, let inferredNiche {
            return inferredNiche
        }

        return nil
    }

    func suggestions(for niche: Niche) -> [NicheSuggestion] {
        if let cached = cachedSuggestionsByNiche[niche] {
            return cached
        }

        let loaded = loadSuggestionsFromBundle(for: niche)
        cachedSuggestionsByNiche[niche] = loaded
        return loaded
    }

    /// Short clause appended to the voice system prompt when a niche is known.
    func voiceSystemPromptClause(for niche: Niche) -> String {
        switch niche {
        case .contentCreator:
            return "the user is a content creator. prioritize help with video editing, captions, exports, color, and timeline navigation on screen. point at specific ui when teaching workflows."
        case .developer:
            return "the user is a developer. prioritize help with code editors, terminals, git, builds, and debugging on screen. point at specific ui when teaching workflows."
        case .student:
            return "the user is a student. prioritize help with assignments, notes, research, and study apps on screen. point at specific ui when teaching workflows."
        case .designer:
            return "the user is a designer. prioritize help with design tools, layers, assets, and export settings on screen. point at specific ui when teaching workflows."
        case .other:
            return "the user works across many apps. prioritize concrete on-screen guidance and pointing when it helps them complete a task."
        }
    }

    private func limitedSuggestions(_ suggestions: [NicheSuggestion]) -> [NicheSuggestion] {
        Array(suggestions.prefix(Self.maximumSuggestionCount))
    }

    private func loadSuggestionsFromBundle(for niche: Niche) -> [NicheSuggestion] {
        let fileURL = bundle.url(
            forResource: niche.rawValue,
            withExtension: "json",
            subdirectory: "niches"
        ) ?? bundle.url(forResource: niche.rawValue, withExtension: "json")

        guard let fileURL else {
            print("⚠️ NicheDiscovery: missing bundled examples for \(niche.rawValue)")
            return []
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(NicheSuggestionsFile.self, from: data)
            return decoded.suggestions
        } catch {
            print("⚠️ NicheDiscovery: failed to load \(niche.rawValue).json: \(error)")
            return []
        }
    }
}
