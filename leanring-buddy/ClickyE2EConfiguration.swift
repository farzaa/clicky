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

    static var restoreSkillID: String? {
        argumentValue(for: "-CLICKY_E2E_RESTORE_SKILL=")
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

    static var skillsCountFileURL: URL {
        clickyDirectoryURL.appendingPathComponent("e2e-skills-count.txt")
    }

    static var skillLibraryStateFileURL: URL {
        clickyDirectoryURL.appendingPathComponent("e2e-skill-library-state.txt")
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

    private static func writeText(_ text: String, to fileURL: URL) {
        try? FileManager.default.createDirectory(at: clickyDirectoryURL, withIntermediateDirectories: true)
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
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
