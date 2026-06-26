//
//  SpiderAccountSessionPolicy.swift
//  leanring-buddy
//
//  Typed account-session decisions for auth, entitlement, billing, and magic
//  links. This file owns metadata-only state rules; it never stores emails,
//  magic links, session tokens, screenshots, transcripts, prompts, or model
//  responses.
//

import Foundation

enum SpiderAccountState: Equatable {
    case loggedOut
    case checking
    case active
    case trial
    case paymentRequired
    case error(String)

    var canUseAI: Bool {
        switch self {
        case .active, .trial:
            return true
        case .loggedOut, .checking, .paymentRequired, .error:
            return false
        }
    }

    var needsPayment: Bool {
        self == .paymentRequired
    }

    var isLoggedIn: Bool {
        switch self {
        case .active, .trial, .paymentRequired:
            return true
        case .loggedOut, .checking, .error:
            return false
        }
    }
}

enum SpiderBillingAction {
    case checkout
    case portal
}

struct SpiderAccountStatusResolution: Equatable {
    let accountState: SpiderAccountState
    let hasSubmittedEmail: Bool
    let loginStatusMessage: String
}

enum SpiderAccountWorkerErrorResolution: Equatable {
    case loggedOut(message: String, clearStoredToken: Bool, shouldShowPanel: Bool)
    case paymentRequired(message: String, shouldShowPanel: Bool)
    case rateLimited(message: String)
    case unchanged
}

enum SpiderAccountSessionPolicy {
    static func statusResolution(
        for status: SpiderLoginStatusResponse
    ) -> SpiderAccountStatusResolution {
        switch status.entitlementStatus {
        case "active":
            return SpiderAccountStatusResolution(
                accountState: .active,
                hasSubmittedEmail: status.authenticated,
                loginStatusMessage: "Spider account active."
            )
        case "trial":
            return SpiderAccountStatusResolution(
                accountState: .trial,
                hasSubmittedEmail: status.authenticated,
                loginStatusMessage: "Spider trial active."
            )
        case "none", "canceled", "blocked":
            return SpiderAccountStatusResolution(
                accountState: .paymentRequired,
                hasSubmittedEmail: status.authenticated,
                loginStatusMessage: "Payment required before Spider can use AI."
            )
        default:
            return SpiderAccountStatusResolution(
                accountState: .paymentRequired,
                hasSubmittedEmail: status.authenticated,
                loginStatusMessage: "Subscription status needs attention."
            )
        }
    }

    static func magicLinkToken(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "spider",
              url.host?.lowercased() == "auth",
              url.path == "/confirm",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              queryItems.count == 1,
              queryItems[0].name == "token",
              let token = queryItems[0].value else {
            return nil
        }

        return SpiderWorkerTokenValidator.normalizedDoubleUUIDV4Token(token)
    }

    static func workerErrorResolution(
        for error: SpiderWorkerClientError
    ) -> SpiderAccountWorkerErrorResolution {
        if error.isAuthenticationExpired {
            return .loggedOut(
                message: "Your Spider session expired. Sign in again.",
                clearStoredToken: true,
                shouldShowPanel: true
            )
        }

        if error.isPaymentRequired {
            return .paymentRequired(
                message: "Payment required before Spider can use AI.",
                shouldShowPanel: true
            )
        }

        if error.isRateLimited {
            return .rateLimited(message: "Spider usage limit reached. Try again later.")
        }

        return .unchanged
    }

    static func accountVerificationFailureMessage(for error: SpiderWorkerClientError) -> String {
        if error.isRateLimited {
            return "Spider is rate-limited. Try again later."
        }
        return "Could not verify account."
    }

    static func billingFailureMessage(
        for error: SpiderWorkerClientError,
        action: SpiderBillingAction
    ) -> String {
        if error.isAuthenticationExpired {
            return "Sign in again before opening billing."
        }

        if error.isRateLimited {
            return "Too many billing attempts. Try again later."
        }

        if error.statusCode == 409 {
            switch action {
            case .checkout:
                return "Subscription is already active. Use the billing portal."
            case .portal:
                return "No billing portal yet. Start checkout first."
            }
        }

        switch action {
        case .checkout:
            return "Could not open checkout. Check Stripe config."
        case .portal:
            return "Could not open billing portal."
        }
    }
}
