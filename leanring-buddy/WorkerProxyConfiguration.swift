//
//  WorkerProxyConfiguration.swift
//  leanring-buddy
//
//  Reads the user-specific Worker endpoint from Application Support and its
//  bearer token from Keychain so neither value has to be committed or bundled.
//

import Foundation
import Security

struct WorkerProxyConfiguration {
    private struct StoredConfiguration: Decodable {
        let workerBaseURL: String
    }

    static let keychainService = "com.clicky.proxy"
    static let keychainAccount = "authorization-token"

    static let shared = load()

    let workerBaseURL: URL?
    let authorizationToken: String?

    var isConfigured: Bool {
        workerBaseURL != nil && authorizationToken?.isEmpty == false
    }

    init(workerBaseURL: URL?, authorizationToken: String?) {
        self.workerBaseURL = workerBaseURL
        self.authorizationToken = authorizationToken
    }

    func endpoint(for route: String) throws -> URL {
        guard let workerBaseURL else {
            throw WorkerProxyConfigurationError.missingConfiguration
        }

        guard isConfigured else {
            throw WorkerProxyConfigurationError.missingToken
        }

        return workerBaseURL.appendingPathComponent(route)
    }

    func authorize(_ request: inout URLRequest) throws {
        guard isConfigured, let authorizationToken else {
            throw workerBaseURL == nil
                ? WorkerProxyConfigurationError.missingConfiguration
                : WorkerProxyConfigurationError.missingToken
        }

        request.setValue("Bearer \(authorizationToken)", forHTTPHeaderField: "Authorization")
    }

    static func load() -> WorkerProxyConfiguration {
        let baseURL: URL?
        if let configurationURL = configurationFileURL,
           let data = try? Data(contentsOf: configurationURL) {
            baseURL = try? workerBaseURL(from: data)
        } else {
            baseURL = nil
        }

        return WorkerProxyConfiguration(
            workerBaseURL: baseURL,
            authorizationToken: readAuthorizationTokenFromKeychain()
        )
    }

    static func workerBaseURL(from data: Data) throws -> URL {
        let storedConfiguration = try JSONDecoder().decode(StoredConfiguration.self, from: data)
        let value = storedConfiguration.workerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let components = URLComponents(string: value),
              components.url != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host,
              !host.isEmpty,
              components.scheme == "https"
                || (components.scheme == "http" && isLocalDevelopmentHost(host)) else {
            throw WorkerProxyConfigurationError.invalidConfiguration
        }

        var normalizedComponents = components
        normalizedComponents.path = ""
        guard let normalizedBaseURL = normalizedComponents.url else {
            throw WorkerProxyConfigurationError.invalidConfiguration
        }

        return normalizedBaseURL
    }

    private static var configurationFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("proxy.json")
    }

    private static func isLocalDevelopmentHost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "[::1]" || host == "::1"
    }

    private static func readAuthorizationTokenFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            return nil
        }

        return token
    }
}

enum WorkerProxyConfigurationError: LocalizedError, Equatable {
    case missingConfiguration
    case missingToken
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Clicky’s Worker is not configured. Run scripts/configure-proxy.sh and restart Clicky."
        case .missingToken:
            return "Clicky’s Worker token is missing from Keychain. Run scripts/configure-proxy.sh and restart Clicky."
        case .invalidConfiguration:
            return "Clicky’s Worker configuration is invalid. Run scripts/configure-proxy.sh and restart Clicky."
        }
    }
}
