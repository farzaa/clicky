//
//  SpiderGroundingPrivacy.swift
//  leanring-buddy
//
//  Hashes grounding identifiers with a local salt before telemetry can use
//  them. Raw UI text and target IDs must not cross this boundary.
//

import CryptoKit
import Foundation

enum SpiderGroundingPrivacy {
    static func privacyHash(for rawValue: String?, maxCharacters: Int = 512) -> String? {
        let normalizedValue = rawValue?.spiderSanitizedSingleLine(maxCharacters: maxCharacters) ?? ""
        guard !normalizedValue.isEmpty,
              let saltData = SpiderSessionStore.loadOrCreateGroundingTelemetrySalt() else {
            return nil
        }

        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: Data(normalizedValue.utf8),
            using: SymmetricKey(data: saltData)
        )
        return authenticationCode.map { String(format: "%02x", $0) }.joined()
    }

    static func targetFingerprintHash(for components: [String]) -> String? {
        privacyHash(
            for: components
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "|"),
            maxCharacters: 1_024
        )
    }

    static func targetElementIdHash(for rawTargetElementId: String?) -> String? {
        privacyHash(
            for: rawTargetElementId,
            maxCharacters: SpiderGroundingTelemetrySanitizer.maxIdentifierCharacters
        )
    }
}
