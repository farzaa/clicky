//
//  NicheDiscoveryManager.swift
//  leanring-buddy
//
//  Loads niche-specific example prompts from bundled JSON and persists the
//  user's selected niche in UserDefaults.
//

import Foundation

struct NicheSuggestion: Identifiable, Equatable, Codable {
    let id: String
    let prompt: String
}

struct NicheSuggestionsFile: Codable {
    let suggestions: [NicheSuggestion]
}

final class NicheDiscoveryManager {
    static let selectedUserNicheUserDefaultsKey = "selectedUserNiche"

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
            case .other: return "Other"
            }
        }
    }

    private let bundle: Bundle
    private let userDefaults: UserDefaults
    private var cachedSuggestionsByNiche: [Niche: [NicheSuggestion]] = [:]

    init(bundle: Bundle = .main, userDefaults: UserDefaults = .standard) {
        self.bundle = bundle
        self.userDefaults = userDefaults
    }

    var selectedNiche: Niche? {
        guard let rawValue = userDefaults.string(forKey: Self.selectedUserNicheUserDefaultsKey) else {
            return nil
        }
        return Niche(rawValue: rawValue)
    }

    func setNiche(_ niche: Niche) {
        userDefaults.set(niche.rawValue, forKey: Self.selectedUserNicheUserDefaultsKey)
    }

    func suggestions(for niche: Niche) -> [NicheSuggestion] {
        if let cached = cachedSuggestionsByNiche[niche] {
            return cached
        }

        let loaded = loadSuggestionsFromBundle(for: niche)
        cachedSuggestionsByNiche[niche] = loaded
        return loaded
    }

    func suggestions(for niche: Niche, frontmostBundleId: String?) -> [NicheSuggestion] {
        if let frontmostBundleId,
           let appSpecificSuggestions = NicheAppSuggestionMapping.appSpecificSuggestions(
               bundleId: frontmostBundleId,
               selectedNiche: niche
           ) {
            return appSpecificSuggestions
        }
        return suggestions(for: niche)
    }

    func contextLabel(for niche: Niche, frontmostBundleId: String?) -> String? {
        guard let frontmostBundleId else { return nil }
        return NicheAppSuggestionMapping.contextLabel(
            bundleId: frontmostBundleId,
            selectedNiche: niche
        )
    }

    func suggestionsForCurrentNiche(frontmostBundleId: String? = nil) -> [NicheSuggestion] {
        guard let selectedNiche else { return [] }
        return suggestions(for: selectedNiche, frontmostBundleId: frontmostBundleId)
    }

    /// Short clause appended to the voice system prompt when a niche is set.
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

    private func loadSuggestionsFromBundle(for niche: Niche) -> [NicheSuggestion] {
        // Xcode may copy `Resources/niches/*.json` flat into the bundle root.
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
