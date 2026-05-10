//
//  VibeIdInstallTokenStore.swift
//
//  Thread-safe Keychain wrapper for the bearer install token issued by
//  vibe-id. Each project gets its own keychain entry, scoped by service
//  name = "vibe-id.<projectId>", so multiple vibe-id-powered apps on the
//  same Mac don't share or stomp tokens.
//
//  Static accessor (no actor isolation) so non-MainActor API clients can
//  read the current token to set Authorization headers without crossing
//  the main actor on every request. An in-memory cache means most reads
//  don't hit the Keychain syscall at all.
//
//  Why the legacy keychain (no kSecUseDataProtectionKeychain): the
//  data-protection keychain on macOS requires a keychain-access-groups
//  entitlement that most apps don't ship. Without it, SecItemAdd fails
//  silently with errSecMissingEntitlement.
//

import Foundation
import Security

public enum VibeIdInstallTokenStore {

    private static let cacheLock = NSLock()
    private static var cachedTokensByProject: [String: String] = [:]
    private static var populatedProjectCacheKeys: Set<String> = []

    /// Returns the currently saved install token for a project, or nil if
    /// the user is signed out for that project. Safe to call from any
    /// thread / actor.
    public static func currentInstallToken(forProjectId projectId: String) -> String? {
        cacheLock.lock()
        if populatedProjectCacheKeys.contains(projectId) {
            let cachedToken = cachedTokensByProject[projectId]
            cacheLock.unlock()
            return cachedToken
        }
        cacheLock.unlock()

        let tokenFromKeychain = readInstallTokenFromKeychain(forProjectId: projectId)

        cacheLock.lock()
        cachedTokensByProject[projectId] = tokenFromKeychain
        populatedProjectCacheKeys.insert(projectId)
        cacheLock.unlock()

        return tokenFromKeychain
    }

    /// Saves the install token to the Keychain, replacing any prior value
    /// for the same project. Returns true on success.
    @discardableResult
    public static func saveInstallToken(_ installToken: String, forProjectId projectId: String) -> Bool {
        guard let tokenData = installToken.data(using: .utf8) else { return false }

        // Always delete first so the ACL on the new entry is clean.
        deleteInstallTokenFromKeychain(forProjectId: projectId)

        var addQuery: [CFString: Any] = baseKeychainQuery(forProjectId: projectId)
        addQuery[kSecValueData] = tokenData
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        let savedSuccessfully = (status == errSecSuccess)

        cacheLock.lock()
        cachedTokensByProject[projectId] = savedSuccessfully ? installToken : nil
        populatedProjectCacheKeys.insert(projectId)
        cacheLock.unlock()

        if !savedSuccessfully {
            print("⚠️ VibeId Keychain: failed to save install token for \(projectId) (OSStatus \(status))")
        }
        return savedSuccessfully
    }

    @discardableResult
    public static func deleteInstallToken(forProjectId projectId: String) -> Bool {
        let result = deleteInstallTokenFromKeychain(forProjectId: projectId)
        cacheLock.lock()
        cachedTokensByProject[projectId] = nil
        populatedProjectCacheKeys.insert(projectId)
        cacheLock.unlock()
        return result
    }

    // MARK: - Private

    private static let keychainAccountName = "install-token"

    private static func keychainServiceName(forProjectId projectId: String) -> String {
        "vibe-id.\(projectId)"
    }

    private static func readInstallTokenFromKeychain(forProjectId projectId: String) -> String? {
        var matchQuery: [CFString: Any] = baseKeychainQuery(forProjectId: projectId)
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
    private static func deleteInstallTokenFromKeychain(forProjectId projectId: String) -> Bool {
        let deleteQuery: [CFString: Any] = baseKeychainQuery(forProjectId: projectId)
        let status = SecItemDelete(deleteQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseKeychainQuery(forProjectId projectId: String) -> [CFString: Any] {
        return [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainServiceName(forProjectId: projectId),
            kSecAttrAccount: keychainAccountName,
        ]
    }
}
