//
//  SecureSettingsStore.swift
//  leanring-buddy
//
//  Stores sensitive local settings in macOS Keychain.
//

import Foundation
import Security

enum SecureSettingsStoreKey: String {
    case openRouterAPIKey = "openrouter_api_key"
    case elevenLabsAPIKey = "elevenlabs_api_key"
}

enum SecureSettingsStoreError: LocalizedError {
    case failedToStoreValue(OSStatus)
    case failedToReadValue(OSStatus)
    case failedToDeleteValue(OSStatus)
    case invalidValueEncoding

    var errorDescription: String? {
        switch self {
        case .failedToStoreValue(let status):
            return "Failed to store secure setting (\(status))."
        case .failedToReadValue(let status):
            return "Failed to read secure setting (\(status))."
        case .failedToDeleteValue(let status):
            return "Failed to delete secure setting (\(status))."
        case .invalidValueEncoding:
            return "Stored secure value is invalid."
        }
    }
}

final class SecureSettingsStore {
    private let serviceName = "so.clicky.settings"

    func stringValue(for secureKey: SecureSettingsStoreKey) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: secureKey.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw SecureSettingsStoreError.failedToReadValue(status)
        }

        guard let valueData = result as? Data else {
            throw SecureSettingsStoreError.invalidValueEncoding
        }

        guard let value = String(data: valueData, encoding: .utf8) else {
            throw SecureSettingsStoreError.invalidValueEncoding
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    func setStringValue(_ newValue: String, for secureKey: SecureSettingsStoreKey) throws {
        let trimmedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedValue.isEmpty {
            try deleteValue(for: secureKey)
            return
        }

        guard let valueData = trimmedValue.data(using: .utf8) else {
            throw SecureSettingsStoreError.invalidValueEncoding
        }

        let lookupQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: secureKey.rawValue
        ]

        let updateValues: [String: Any] = [
            kSecValueData as String: valueData
        ]

        let updateStatus = SecItemUpdate(lookupQuery as CFDictionary, updateValues as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = lookupQuery
            addQuery[kSecValueData as String] = valueData
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SecureSettingsStoreError.failedToStoreValue(addStatus)
            }
            return
        }

        guard updateStatus == errSecSuccess else {
            throw SecureSettingsStoreError.failedToStoreValue(updateStatus)
        }
    }

    func deleteValue(for secureKey: SecureSettingsStoreKey) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: secureKey.rawValue
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureSettingsStoreError.failedToDeleteValue(status)
        }
    }
}
