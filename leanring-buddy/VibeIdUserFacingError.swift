//
//  VibeIdUserFacingError.swift
//  leanring-buddy
//
//  Small shared helpers for converting vibe-id billing/quota responses into
//  messages the macOS app can show directly to the user.
//

import Foundation

struct VibeIdInsufficientCreditsError: LocalizedError {
    let statusCode: Int
    let endpoint: String?
    let balance: Int?
    let required: Int?
    let responseBody: String

    static let refillAccountURLString = "https://vibe-research.net/account.html"
    static let refillAccountDisplayText = "vibe-research.net/account"
    static let supportProfileURLString = "https://x.com/clamepending"
    static let supportHandleDisplayText = "@clamepending"

    static let plainMessage = "Your Dot credits are too low for that request. Refill your account at vibe-research.net/account, or DM me on X at @clamepending."

    static let markdownMessage = """
    Your Dot credits are too low for that request.

    Refill your account at [vibe-research.net/account](https://vibe-research.net/account.html), or DM me on X at [@clamepending](https://x.com/clamepending).
    """

    static let spokenMessage = "Your Dot credits are too low for that request. Refill your account at vibe-research.net slash account, or DM me on X at clamepending."

    var errorDescription: String? {
        Self.plainMessage
    }
}

enum VibeIdUserFacingError {
    static func insufficientCreditsErrorIfApplicable(
        statusCode: Int,
        responseBody: String,
        fallbackEndpoint: String? = nil
    ) -> VibeIdInsufficientCreditsError? {
        guard statusCode == 402 else { return nil }

        let trimmedResponseBody = responseBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedJSON = parseJSONObject(from: trimmedResponseBody)
        let errorCode = parsedJSON?["error"] as? String
        let lowercaseBody = trimmedResponseBody.lowercased()

        guard errorCode == "insufficient_credits" || lowercaseBody.contains("insufficient_credits") else {
            return nil
        }

        return VibeIdInsufficientCreditsError(
            statusCode: statusCode,
            endpoint: parsedJSON?["endpoint"] as? String ?? fallbackEndpoint,
            balance: parsedJSON?["balance"] as? Int,
            required: parsedJSON?["required"] as? Int ?? parsedJSON?["requested"] as? Int,
            responseBody: trimmedResponseBody
        )
    }

    static func insufficientCreditsErrorIfApplicable(_ error: Error) -> VibeIdInsufficientCreditsError? {
        if let insufficientCreditsError = error as? VibeIdInsufficientCreditsError {
            return insufficientCreditsError
        }

        let nsError = error as NSError
        return insufficientCreditsErrorIfApplicable(
            statusCode: nsError.code,
            responseBody: error.localizedDescription
        )
    }

    static func plainMessageIfApplicable(_ error: Error) -> String? {
        guard insufficientCreditsErrorIfApplicable(error) != nil else { return nil }
        return VibeIdInsufficientCreditsError.plainMessage
    }

    static func isInsufficientCreditsMessage(_ message: String) -> Bool {
        message == VibeIdInsufficientCreditsError.plainMessage
            || message.contains("insufficient_credits")
    }

    private static func parseJSONObject(from responseBody: String) -> [String: Any]? {
        guard let responseData = responseBody.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: responseData) as? [String: Any]
    }
}
