//
//  KeychainHelper.swift
//  leanring-buddy
//
//  Thin wrapper around the Security framework for storing API keys in
//  the macOS Keychain. Keys are stored as generic passwords keyed by
//  the app's bundle identifier (service) and a per-key account name.
//
//  We deliberately do NOT use UserDefaults for API keys: UserDefaults is
//  a plist on disk readable by anyone with file access, while the
//  Keychain is encrypted and access-controlled by macOS.
//

import Foundation
import Security

enum KeychainHelper {
    /// Service identifier shared across all Keychain entries written by
    /// this app. Using `Bundle.main.bundleIdentifier` keeps the entries
    /// scoped to this app — different builds (debug, release) with
    /// different bundle IDs won't collide.
    private static var serviceIdentifier: String {
        Bundle.main.bundleIdentifier ?? "com.clicky.leanring-buddy"
    }

    /// Saves a string value to the Keychain under the given account name.
    /// Overwrites any existing value. Returns true on success.
    @discardableResult
    static func saveString(_ value: String, forAccount accountName: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete any existing entry first so we can perform a clean add.
        // SecItemUpdate is finicky about which attributes are required;
        // delete-then-add is simpler and reliable for our use case.
        deleteString(forAccount: accountName)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: accountName,
            kSecValueData as String: data,
            // Only allow access when this device is unlocked, and never
            // sync to iCloud Keychain — these are device-local secrets.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Reads a string value from the Keychain under the given account name.
    /// Returns nil if the entry doesn't exist or can't be decoded.
    static func readString(forAccount accountName: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: accountName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let stringValue = String(data: data, encoding: .utf8) else {
            return nil
        }
        return stringValue
    }

    /// Deletes the Keychain entry for the given account name. Safe to
    /// call when no entry exists — a missing entry is treated as success.
    @discardableResult
    static func deleteString(forAccount accountName: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceIdentifier,
            kSecAttrAccount as String: accountName
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
