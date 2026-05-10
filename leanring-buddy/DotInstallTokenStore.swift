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
//  Two design notes:
//
//  1. We use the modern data-protection keychain (`kSecUseDataProtectionKeychain`).
//     On macOS that means access is scoped to (Team Identifier + Bundle ID), the
//     same way iOS works. Without this flag we fall back to the legacy file-based
//     keychain, which uses a per-app ACL and pops "Dot wants to use your
//     confidential information stored in net.vibe-research.dot" every time a
//     differently-signed build reads it (very common during local rebuilds).
//
//  2. After the first successful read we cache the token in memory. Every
//     authenticated API call would otherwise issue a SecItemCopyMatching syscall
//     just to add a header — wasteful, especially during the streaming Claude
//     and AssemblyAI sessions. The cache is invalidated on save/delete.
//

import Foundation
import Security

/// Static accessor for the long-lived install token. Stored in the macOS
/// data-protection Keychain under a service+account that's stable across app
/// launches and rebuilds (as long as the bundle id and signing team are unchanged).
enum DotInstallTokenStore {

    private static let keychainServiceName = "net.vibe-research.dot"
    private static let keychainAccountName = "install-token"

    // In-memory cache. cachedTokenIsPopulated avoids confusing nil-cache vs
    // cached-as-nil. NSLock is enough — the keychain syscall happens at most
    // once per process under contention.
    private static let cacheLock = NSLock()
    private static var cachedInstallToken: String? = nil
    private static var cachedTokenIsPopulated: Bool = false

    /// Returns the currently saved install token, or nil if the user is signed out.
    /// Safe to call from any thread / actor.
    static func currentInstallToken() -> String? {
        cacheLock.lock()
        if cachedTokenIsPopulated {
            let token = cachedInstallToken
            cacheLock.unlock()
            return token
        }
        cacheLock.unlock()

        let tokenFromKeychain = readInstallTokenFromKeychain()

        cacheLock.lock()
        cachedInstallToken = tokenFromKeychain
        cachedTokenIsPopulated = true
        cacheLock.unlock()

        return tokenFromKeychain
    }

    /// Saves the install token to the Keychain, replacing any prior value.
    @discardableResult
    static func saveInstallToken(_ installToken: String) -> Bool {
        guard let tokenData = installToken.data(using: .utf8) else { return false }

        // Delete any existing entry from BOTH the data-protection keychain and
        // the legacy keychain. Local dev installs from earlier ad-hoc-signed
        // builds may have left a stale entry in the legacy keychain that would
        // otherwise keep prompting for a password. We don't want it.
        deleteInstallTokenFromAllKeychains()

        var addQuery: [CFString: Any] = baseKeychainQuery()
        addQuery[kSecValueData] = tokenData
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        let savedSuccessfully = (status == errSecSuccess)

        cacheLock.lock()
        cachedInstallToken = savedSuccessfully ? installToken : nil
        cachedTokenIsPopulated = savedSuccessfully
        cacheLock.unlock()

        if !savedSuccessfully {
            print("⚠️ Dot Keychain: failed to save install token (status \(status))")
        }
        return savedSuccessfully
    }

    /// Removes the install token from the Keychain. Idempotent.
    @discardableResult
    static func deleteInstallToken() -> Bool {
        let deleted = deleteInstallTokenFromAllKeychains()
        cacheLock.lock()
        cachedInstallToken = nil
        cachedTokenIsPopulated = true
        cacheLock.unlock()
        return deleted
    }

    // MARK: - Private

    private static func readInstallTokenFromKeychain() -> String? {
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

    @discardableResult
    private static func deleteInstallTokenFromAllKeychains() -> Bool {
        let dataProtectionQuery: [CFString: Any] = baseKeychainQuery()
        let dataProtectionStatus = SecItemDelete(dataProtectionQuery as CFDictionary)
        let dataProtectionSucceeded = dataProtectionStatus == errSecSuccess
            || dataProtectionStatus == errSecItemNotFound

        // Also clear the legacy keychain entry that older ad-hoc builds may
        // have left behind. Without kSecUseDataProtectionKeychain the API
        // targets the legacy keychain.
        var legacyQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainServiceName,
            kSecAttrAccount: keychainAccountName,
        ]
        legacyQuery[kSecUseDataProtectionKeychain] = false
        let legacyStatus = SecItemDelete(legacyQuery as CFDictionary)
        let legacySucceeded = legacyStatus == errSecSuccess
            || legacyStatus == errSecItemNotFound

        return dataProtectionSucceeded && legacySucceeded
    }

    private static func baseKeychainQuery() -> [CFString: Any] {
        return [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainServiceName,
            kSecAttrAccount: keychainAccountName,
            // Use the modern data-protection keychain. On macOS this scopes
            // the item to (Team Identifier + Bundle ID), so the OS doesn't
            // pop a password prompt when a re-signed build reads its own token.
            kSecUseDataProtectionKeychain: true,
        ]
    }
}
