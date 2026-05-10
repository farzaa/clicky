//
//  DotInstallTokenStore.swift
//  leanring-buddy
//
//  Thread-safe Keychain wrapper for the bearer install token that authenticates
//  the macOS app against the Dot inference gateway.
//
//  We deliberately split this from DotAccountManager so that non-MainActor API
//  clients (ClaudeAPI, ElevenLabsTTSClient, AssemblyAIStreamingTranscriptionProvider)
//  can read the current token to set Authorization headers without crossing the
//  main actor on every request.
//

import Foundation
import Security

/// Static accessor for the long-lived install token. Stored in the macOS Keychain
/// under a service+account that's stable across app launches and reinstalls (as long
/// as the bundle id is unchanged).
enum DotInstallTokenStore {

    private static let keychainServiceName = "net.vibe-research.dot"
    private static let keychainAccountName = "install-token"

    /// Returns the currently saved install token, or nil if the user is signed out.
    /// Safe to call from any thread / actor.
    static func currentInstallToken() -> String? {
        var matchQuery: [CFString: Any] = baseKeychainQuery()
        matchQuery[kSecReturnData] = true
        matchQuery[kSecMatchLimit] = kSecMatchLimitOne

        var fetchedItem: AnyObject?
        let status = SecItemCopyMatching(matchQuery as CFDictionary, &fetchedItem)
        guard status == errSecSuccess,
              let tokenData = fetchedItem as? Data,
              let token = String(data: tokenData, encoding: .utf8),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    /// Saves the install token to the Keychain, replacing any prior value.
    @discardableResult
    static func saveInstallToken(_ installToken: String) -> Bool {
        guard let tokenData = installToken.data(using: .utf8) else { return false }

        // Delete any existing entry first so we don't leave duplicates if the
        // attribute set ever drifts. SecItemUpdate would also work but Add+Delete
        // is simpler to reason about.
        deleteInstallToken()

        var addQuery: [CFString: Any] = baseKeychainQuery()
        addQuery[kSecValueData] = tokenData
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            print("⚠️ Dot Keychain: failed to save install token (status \(status))")
            return false
        }
        return true
    }

    /// Removes the install token from the Keychain. Idempotent.
    @discardableResult
    static func deleteInstallToken() -> Bool {
        let deleteQuery: [CFString: Any] = baseKeychainQuery()
        let status = SecItemDelete(deleteQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseKeychainQuery() -> [CFString: Any] {
        return [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainServiceName,
            kSecAttrAccount: keychainAccountName,
        ]
    }
}
