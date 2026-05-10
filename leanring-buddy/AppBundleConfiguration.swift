//
//  AppBundleConfiguration.swift
//  leanring-buddy
//
//  Shared helper for reading runtime configuration from the built app bundle.
//

import Foundation

enum AppBundleConfiguration {
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

    static func proxyBaseURLString() -> String {
        let configuredProxyBaseURL = stringValue(forKey: "DotProxyBaseURL")
            ?? "http://127.0.0.1:8787"
        return configuredProxyBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Base URL for the central identity service (vibe-id). Used by
    /// DotAccountManager for sign-in, /auth/me, and sign-out — distinct from
    /// the per-project Dot inference proxy returned by `proxyBaseURLString()`.
    static func vibeIdBaseURLString() -> String {
        let configured = stringValue(forKey: "VibeIdBaseURL")
            ?? "http://127.0.0.1:8790"
        return configured.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
