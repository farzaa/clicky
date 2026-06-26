//
//  SpiderSessionStore.swift
//  leanring-buddy
//
//  Keychain-backed storage for Worker session tokens and the stable device
//  identifier used by server-side rate limits.
//

import Foundation
import Security

enum SpiderSessionStoreError: LocalizedError {
    case couldNotEncodeValue
    case invalidSessionToken
    case keychainReadFailed
    case keychainWriteFailed
    case keychainDeleteFailed

    var errorDescription: String? {
        switch self {
        case .couldNotEncodeValue:
            return "Could not encode the Spider Keychain value."
        case .invalidSessionToken:
            return "Spider session token is invalid."
        case .keychainReadFailed:
            return "Could not read from the Spider Keychain store."
        case .keychainWriteFailed:
            return "Could not save to the Spider Keychain store."
        case .keychainDeleteFailed:
            return "Could not delete from the Spider Keychain store."
        }
    }
}

enum SpiderWorkerTokenValidator {
    nonisolated private static let doubleUUIDV4TokenPattern = #"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"#

    nonisolated static func normalizedDoubleUUIDV4Token(_ value: String) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedValue.range(of: doubleUUIDV4TokenPattern, options: .regularExpression) != nil else {
            return nil
        }
        return trimmedValue
    }
}

enum SpiderSessionStore {
    private static let maxDeviceIdentifierCharacters = 128
    private static let service = Bundle.main.bundleIdentifier ?? "com.spider.mac"
    private static let sessionTokenAccount = "spider.session-token"
    private static let deviceIdentifierAccount = "spider.device-id"
    private static let groundingTelemetrySaltAccount = "spider.grounding-telemetry-salt"
    private static let groundingTelemetrySaltByteCount = 32

    static func loadSessionToken() throws -> String? {
        guard let loadedSessionToken = try loadValue(account: sessionTokenAccount) else {
            return nil
        }
        guard let sessionToken = normalizedSessionToken(loadedSessionToken) else {
            try? deleteValue(account: sessionTokenAccount)
            return nil
        }
        if sessionToken != loadedSessionToken {
            try? saveValue(sessionToken, account: sessionTokenAccount)
        }
        return sessionToken
    }

    static func saveSessionToken(_ sessionToken: String) throws {
        guard let normalizedToken = normalizedSessionToken(sessionToken) else {
            throw SpiderSessionStoreError.invalidSessionToken
        }
        try saveValue(normalizedToken, account: sessionTokenAccount)
    }

    static func clearSessionToken() throws {
        try deleteValue(account: sessionTokenAccount)
    }

    static func loadOrCreateDeviceIdentifier() -> String {
        if let existingDeviceIdentifier = try? loadValue(account: deviceIdentifierAccount),
           let normalizedDeviceIdentifier = normalizedDeviceIdentifier(existingDeviceIdentifier) {
            if normalizedDeviceIdentifier != existingDeviceIdentifier {
                try? saveValue(normalizedDeviceIdentifier, account: deviceIdentifierAccount)
            }
            return normalizedDeviceIdentifier
        }

        let newDeviceIdentifier = UUID().uuidString
        try? saveValue(newDeviceIdentifier, account: deviceIdentifierAccount)
        return newDeviceIdentifier
    }

    static func loadOrCreateGroundingTelemetrySalt() -> Data? {
        if let existingSalt = try? loadValue(account: groundingTelemetrySaltAccount),
           let saltData = Data(base64Encoded: existingSalt),
           saltData.count == groundingTelemetrySaltByteCount {
            return saltData
        }

        guard let saltData = randomData(byteCount: groundingTelemetrySaltByteCount) else {
            return nil
        }

        try? saveValue(saltData.base64EncodedString(), account: groundingTelemetrySaltAccount)
        return saltData
    }

    private static func normalizedDeviceIdentifier(_ value: String) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedValue.count <= maxDeviceIdentifierCharacters,
              let uuid = UUID(uuidString: trimmedValue) else {
            return nil
        }
        return uuid.uuidString
    }

    private static func normalizedSessionToken(_ value: String) -> String? {
        SpiderWorkerTokenValidator.normalizedDoubleUUIDV4Token(value)
    }

    private static func loadValue(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw SpiderSessionStoreError.keychainReadFailed
        }
        guard let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func saveValue(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw SpiderSessionStoreError.couldNotEncodeValue
        }

        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }

        if addStatus == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery(account: account) as CFDictionary,
                [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                ] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw SpiderSessionStoreError.keychainWriteFailed
            }
            return
        }

        throw SpiderSessionStoreError.keychainWriteFailed
    }

    private static func deleteValue(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }
        throw SpiderSessionStoreError.keychainDeleteFailed
    }

    private static func randomData(byteCount: Int) -> Data? {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        guard status == errSecSuccess else {
            return nil
        }
        return Data(bytes)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }
}
