//
//  EncryptedStore.swift
//  yardtalk
//
//  AEAD wrapper around at-rest JSON files. Uses ChaChaPoly with a
//  256-bit symmetric key stored in the Keychain
//  (kSecAttrAccessibleWhenUnlockedThisDeviceOnly, same class as the
//  Anthropic API key and the NU PAT — see KeychainService).
//
//  On-disk format: 4-byte magic "YT01" followed by the ChaChaPoly
//  combined representation (nonce | ciphertext | tag). The magic
//  lets `read(from:)` distinguish files written before this change
//  (plaintext JSON, which never starts with 'Y') and pass them
//  through — the next `write(_:to:)` will encrypt them. This is
//  the option-(b) migration policy: existing sessions are kept,
//  not deleted, and re-encrypted on first re-write.
//
//  Threat model: protects against another logged-in macOS user
//  reading the JSON files directly (the Keychain item is
//  ThisDeviceOnly and access-controlled per app). Does NOT
//  protect against code execution as the user — an attacker who
//  can run as you reads the Keychain item the same way the app
//  does. The original audit accepted that boundary; this layer
//  exists so plaintext narration/summary doesn't sit on disk
//  recoverable by any process that can stat the home directory.
//

import CryptoKit
import Foundation

enum EncryptedStore {
    private static let magic: [UInt8] = Array("YT01".utf8)
    private static let keychainKey = "at-rest-encryption-key-v1"

    enum EncryptedStoreError: Error {
        case decryptionFailed
    }

    /// Serializes `data` to `url` encrypted with the at-rest key.
    /// Writes atomically so a crash mid-write can't corrupt the
    /// previous version.
    static func write(_ data: Data, to url: URL) throws {
        let key = try loadOrCreateKey()
        let sealed = try ChaChaPoly.seal(data, using: key)
        var out = Data(magic)
        out.append(sealed.combined)
        try out.write(to: url, options: .atomic)
    }

    /// Reads `url`. Files carrying the magic header are decrypted;
    /// older plaintext files are returned as-is so the caller can
    /// decode them with its existing JSONDecoder. Callers that
    /// also `write(_:to:)` after a successful read will transparently
    /// migrate those files to the encrypted format.
    static func read(from url: URL) throws -> Data {
        let raw = try Data(contentsOf: url)
        guard raw.count >= magic.count,
              raw.prefix(magic.count).elementsEqual(magic) else {
            return raw
        }
        let key = try loadOrCreateKey()
        let sealedBytes = raw.dropFirst(magic.count)
        do {
            let box = try ChaChaPoly.SealedBox(combined: sealedBytes)
            return try ChaChaPoly.open(box, using: key)
        } catch {
            throw EncryptedStoreError.decryptionFailed
        }
    }

    private static func loadOrCreateKey() throws -> SymmetricKey {
        if let data = KeychainService.readData(key: keychainKey) {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        try KeychainService.saveData(key: keychainKey, data: raw)
        return key
    }
}
