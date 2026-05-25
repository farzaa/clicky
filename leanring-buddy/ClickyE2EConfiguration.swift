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

    static func applyLaunchOverrides() {
        guard isEnabled else { return }

        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")
        UserDefaults.standard.set(true, forKey: "isClickyCursorEnabled")
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
