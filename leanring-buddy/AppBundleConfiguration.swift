//
//  AppBundleConfiguration.swift
//  leanring-buddy
//
//  Shared helper for reading runtime configuration from the built app bundle.
//

import Foundation

enum AppBundleConfiguration {
    private static let placeholderWorkerBaseURL = "https://your-worker-name.your-subdomain.workers.dev"

    /// Cloudflare Worker base URL for Claude, TTS, and AssemblyAI token routes.
    /// Set `ClickyWorkerBaseURL` in Info.plist (no trailing slash).
    static var workerBaseURL: String {
        stringValue(forKey: "ClickyWorkerBaseURL") ?? placeholderWorkerBaseURL
    }

    static var isWorkerBaseURLConfigured: Bool {
        workerBaseURL != placeholderWorkerBaseURL
    }

    static func stringValue(forKey key: String) -> String? {
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedValue.isEmpty {
                return trimmedValue
            }
        }

        guard let resourceInfoPath = Bundle.main.path(forResource: "Info", ofType: "plist"),
              let resourceInfo = NSDictionary(contentsOfFile: resourceInfoPath),
              let value = resourceInfo[key] as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}
