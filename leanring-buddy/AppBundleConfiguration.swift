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
}

enum SpiderConfiguration {
    private static let feedbackEmailPattern = #"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#
    private static let localDevelopmentHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    static var isDevelopmentBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    static var workerBaseURL: URL {
        guard let configuredURLString = AppBundleConfiguration.stringValue(forKey: "SpiderWorkerBaseURL") else {
            preconditionFailure("SpiderWorkerBaseURL must be configured.")
        }
        guard let configuredURL = URL(string: configuredURLString) else {
            preconditionFailure("SpiderWorkerBaseURL must be a valid absolute URL.")
        }
        return validatedWorkerBaseURL(configuredURL)
    }

    static var feedbackEmail: String? {
        guard let configuredEmail = AppBundleConfiguration.stringValue(forKey: "SpiderFeedbackEmail") else {
            return nil
        }
        let normalizedEmail = configuredEmail.lowercased()
        guard normalizedEmail.range(
            of: feedbackEmailPattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil else {
            return nil
        }
        return normalizedEmail
    }

    static var feedbackMailURL: URL? {
        guard let feedbackEmail else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = feedbackEmail
        return components.url
    }

    static var deviceIdentifier: String {
        SpiderSessionStore.loadOrCreateDeviceIdentifier()
    }

    static var sessionBearerToken: String? {
        if let keychainSessionToken = try? SpiderSessionStore.loadSessionToken(),
           !keychainSessionToken.isEmpty {
            return keychainSessionToken
        }
        #if DEBUG
        guard let developmentSessionToken = AppBundleConfiguration.stringValue(forKey: "SpiderDevelopmentSessionToken") else {
            return nil
        }
        return SpiderWorkerTokenValidator.normalizedDoubleUUIDV4Token(developmentSessionToken)
        #else
        return nil
        #endif
    }

    static func endpoint(_ path: String) -> URL {
        path
            .split(separator: "/")
            .reduce(workerBaseURL) { partialURL, pathComponent in
                partialURL.appendingPathComponent(String(pathComponent))
            }
    }

    private static func validatedWorkerBaseURL(_ url: URL) -> URL {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !host.isEmpty,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            preconditionFailure("SpiderWorkerBaseURL must be a clean absolute origin URL.")
        }

        if isDevelopmentBuild, localDevelopmentHosts.contains(host) {
            guard scheme == "http" || scheme == "https" else {
                preconditionFailure("SpiderWorkerBaseURL local development URLs must use HTTP or HTTPS.")
            }
            return url
        }

        guard scheme == "https" else {
            preconditionFailure("SpiderWorkerBaseURL must use HTTPS outside local development.")
        }
        guard url.port == nil else {
            preconditionFailure("SpiderWorkerBaseURL must not include an explicit port outside local development.")
        }
        if !isDevelopmentBuild, host.contains("example.com") {
            preconditionFailure("SpiderWorkerBaseURL must not point to example.com in release builds.")
        }
        return url
    }
}
