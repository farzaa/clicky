//
//  ClickyE2EConfiguration.swift
//  leanring-buddy
//
//  Launch flags used by automated end-to-end tests.
//

import Foundation

enum ClickyE2EConfiguration {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-CLICKY_E2E=1")
    }

    static var shouldIncludeNicheFlow: Bool {
        ProcessInfo.processInfo.arguments.contains("-CLICKY_E2E_INCLUDE_NICHE=1")
    }

    static var workerBaseURL: String? {
        argumentValue(for: "-CLICKY_WORKER_URL=")
    }

    static var injectTranscript: String? {
        argumentValue(for: "-CLICKY_INJECT_TRANSCRIPT=")
    }

    static var injectTranscript2: String? {
        argumentValue(for: "-CLICKY_INJECT_TRANSCRIPT_2=")
    }

    static var injectTranscript3: String? {
        argumentValue(for: "-CLICKY_INJECT_TRANSCRIPT_3=")
    }

    static var selectNicheOnLaunch: String? {
        argumentValue(for: "-CLICKY_E2E_SELECT_NICHE=")
    }

    static var simulateFrontmostBundleID: String? {
        argumentValue(for: "-CLICKY_E2E_SIMULATE_FRONTMOST_BUNDLE=")
    }

    static var injectSuggestionTapText: String? {
        argumentValue(for: "-CLICKY_E2E_INJECT_SUGGESTION_TAP=")
    }

    static var restoreSkillID: String? {
        argumentValue(for: "-CLICKY_E2E_RESTORE_SKILL=")
    }

    static var e2eSetNicheRawValue: String? {
        argumentValue(for: "-CLICKY_E2E_SET_NICHE=") ?? selectNicheOnLaunch
    }

    static var e2eTapSuggestionID: String? {
        argumentValue(for: "-CLICKY_E2E_TAP_SUGGESTION=")
    }

    static var e2eFrontmostBundleId: String? {
        argumentValue(for: "-CLICKY_E2E_FRONTMOST_BUNDLE_ID=") ?? simulateFrontmostBundleID
    }

    static var clickyDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clicky", isDirectory: true)
    }

    static var lastSystemPromptFileURL: URL {
        clickyDirectoryURL.appendingPathComponent("e2e-last-system-prompt.txt")
    }

    static var lastMatchedSkillIDFileURL: URL {
        clickyDirectoryURL.appendingPathComponent("e2e-last-matched-skill-id.txt")
    }

    static var lastSuggestionsFileURL: URL {
        clickyDirectoryURL.appendingPathComponent("e2e-last-suggestions.txt")
    }

    static var selectedNicheFileURL: URL {
        clickyDirectoryURL.appendingPathComponent("e2e-selected-niche.txt")
    }

    static var skillsCountFileURL: URL {
        clickyDirectoryURL.appendingPathComponent("e2e-skills-count.txt")
    }

    static var skillLibraryStateFileURL: URL {
        clickyDirectoryURL.appendingPathComponent("e2e-skill-library-state.txt")
    }

    static var nicheDiscoveryFileURL: URL {
        clickyDirectoryURL.appendingPathComponent("e2e-niche-discovery.json")
    }

    struct NicheDiscoveryE2ESnapshot: Codable {
        let selectedNiche: String
        let suggestionCount: Int
        let firstSuggestionId: String
        let voicePromptClauseContains: String
        let suggestionContext: String?
        let isAppAware: Bool
    }

    static func applyLaunchOverrides() {
        guard isEnabled else { return }

        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")
        UserDefaults.standard.set(true, forKey: "isClickyCursorEnabled")
    }

    static func writeLastSystemPromptForE2E(_ systemPrompt: String) {
        guard isEnabled else { return }
        writeText(systemPrompt, to: lastSystemPromptFileURL)
    }

    static func writeLastMatchedSkillIDForE2E(_ skillID: String?) {
        guard isEnabled else { return }

        if let skillID {
            writeText(skillID, to: lastMatchedSkillIDFileURL)
        } else {
            try? FileManager.default.removeItem(at: lastMatchedSkillIDFileURL)
        }
    }

    static func writeSelectedNicheForE2E(_ nicheRawValue: String) {
        guard isEnabled else { return }
        writeText(nicheRawValue, to: selectedNicheFileURL)
    }

    static func writeLastSuggestionsForE2E(_ suggestions: [String]) {
        guard isEnabled else { return }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: suggestions, options: [.prettyPrinted]),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }
        writeText(jsonString, to: lastSuggestionsFileURL)
    }

    static func writeSkillsCountForE2E(_ skillsCount: Int) {
        guard isEnabled else { return }
        writeText(String(skillsCount), to: skillsCountFileURL)
    }

    static func writeSkillLibraryStateForE2E(_ skills: [TeachingSkill]) {
        guard isEnabled else { return }

        let libraryEntries = skills.map { skill in
            [
                "id": skill.id,
                "status": skill.status.rawValue,
                "pinned": skill.isPinned
            ] as [String: Any]
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: libraryEntries, options: [.prettyPrinted]),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }
        writeText(jsonString, to: skillLibraryStateFileURL)
    }

    static func writeNicheDiscoveryForE2E(_ snapshot: NicheDiscoveryE2ESnapshot) {
        guard isEnabled else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(snapshot) else { return }
        writeData(data, to: nicheDiscoveryFileURL)
    }

    static func writeSuggestionsForE2E(_ suggestionPrompts: [String]) {
        guard isEnabled else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        guard let data = try? encoder.encode(suggestionPrompts) else { return }
        writeData(data, to: lastSuggestionsFileURL)
    }

    private static func writeText(_ text: String, to fileURL: URL) {
        try? FileManager.default.createDirectory(at: clickyDirectoryURL, withIntermediateDirectories: true)
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private static func writeData(_ data: Data, to fileURL: URL) {
        try? FileManager.default.createDirectory(at: clickyDirectoryURL, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func argumentValue(for prefix: String) -> String? {
        ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix(prefix) })
            .map { String($0.dropFirst(prefix.count)) }
            .flatMap { value in
                value.isEmpty ? nil : value
            }
    }
}
