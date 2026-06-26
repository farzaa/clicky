//
//  SpiderWorkerClientError.swift
//  leanring-buddy
//
//  Shared sanitized Worker error. Keep this status-based so UI decisions never
//  depend on parsing server text or logging response bodies.
//

import Foundation

struct SpiderWorkerClientError: LocalizedError, Equatable {
    let statusCode: Int
    let operation: String

    var isAuthenticationExpired: Bool {
        statusCode == 401
    }

    var isPaymentRequired: Bool {
        statusCode == 402 || statusCode == 403
    }

    var isRateLimited: Bool {
        statusCode == 429
    }

    var isPayloadTooLarge: Bool {
        statusCode == 413
    }

    var errorDescription: String? {
        switch statusCode {
        case 401:
            return "Sign in to Spider again."
        case 402, 403:
            return "An active Spider subscription is required."
        case 413:
            return "The screenshot payload is too large."
        case 429:
            return "Spider usage limit reached. Try again later."
        default:
            return "Spider server request failed (\(statusCode))."
        }
    }
}
