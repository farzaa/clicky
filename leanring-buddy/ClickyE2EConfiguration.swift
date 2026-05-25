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

    static var e2eSetNicheRawValue: String? {
        argumentValue(for: "-CLICKY_E2E_SET_NICHE=")
    }

    static var e2eTapSuggestionID: String? {
        argumentValue(for: "-CLICKY_E2E_TAP_SUGGESTION=")
    }

    static var lastSystemPromptFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clicky/e2e-last-system-prompt.txt")
    }

    static var nicheDiscoveryFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clicky/e2e-niche-discovery.json")
    }

    struct NicheDiscoveryE2ESnapshot: Codable {
        let selectedNiche: String
        let suggestionCount: Int
        let firstSuggestionId: String
        let voicePromptClauseContains: String
    }

    static func applyLaunchOverrides() {
        guard isEnabled else { return }

        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")
        UserDefaults.standard.set(true, forKey: "isClickyCursorEnabled")
    }

    static func writeLastSystemPromptForE2E(_ systemPrompt: String) {
        guard isEnabled else { return }

        let directory = lastSystemPromptFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? systemPrompt.write(to: lastSystemPromptFileURL, atomically: true, encoding: .utf8)
    }

    static func writeNicheDiscoveryForE2E(_ snapshot: NicheDiscoveryE2ESnapshot) {
        guard isEnabled else { return }

        let directory = nicheDiscoveryFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: nicheDiscoveryFileURL, options: .atomic)
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
