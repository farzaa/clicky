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
//  1. We use the legacy file-based keychain (the default — no
//     kSecUseDataProtectionKeychain). The data-protection keychain looks
//     cleaner because it's scoped by Team Identifier the way iOS is, but on
//     macOS it requires an explicit keychain-access-groups entitlement that
//     this app doesn't ship with. Without that entitlement, SecItemAdd with
//     kSecUseDataProtectionKeychain silently fails (errSecMissingEntitlement,
//     -34018), the token never lands, and the panel snaps back to "Sign in"
//     with no visible error.
//
//  2. After the first successful read we cache the token in memory. Every
//     authenticated API call would otherwise issue a SecItemCopyMatching
//     syscall just to add a header — wasteful, especially during the
//     streaming Claude and AssemblyAI sessions. The cache is invalidated on
//     save / delete.
//
//  The first time the user signs in on a freshly-signed build, macOS will
//  show the "Dot wants to use your confidential information" prompt once
//  (because the ACL doesn't yet include the Developer ID identity). Clicking
//  Always Allow fixes it for good. As long as the signing identity stays
//  the same across rebuilds, future reads don't prompt.
//

import Foundation
import Security

enum DotInstallTokenStore {

    private static let keychainServiceName = "net.vibe-research.dot"
    private static let keychainAccountName = "install-token"

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
    /// Returns true on success, false otherwise. Failures are logged so they
    /// surface in development; callers should also treat false as "user is
    /// effectively signed out" and reflect that in the UI.
    @discardableResult
    static func saveInstallToken(_ installToken: String) -> Bool {
        guard let tokenData = installToken.data(using: .utf8) else { return false }

        // Always delete first so the ACL on the new entry is clean — we don't
        // want stale per-app trust lists from prior builds that signed under a
        // different identity (e.g. ad-hoc local installs).
        deleteInstallTokenFromKeychain()

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
            print("⚠️ Dot Keychain: failed to save install token (OSStatus \(status))")
        }
        return savedSuccessfully
    }

    /// Removes the install token from the Keychain. Idempotent.
    @discardableResult
    static func deleteInstallToken() -> Bool {
        let deleted = deleteInstallTokenFromKeychain()
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
    private static func deleteInstallTokenFromKeychain() -> Bool {
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
