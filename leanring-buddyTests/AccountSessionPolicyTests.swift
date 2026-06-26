//
//  AccountSessionPolicyTests.swift
//  leanring-buddyTests
//
//  Domain tests for account session and billing policy mapping.
//

import Foundation
import Testing
@testable import Spider

@MainActor
struct AccountSessionPolicyTests {
    @Test func mapsEntitlementStatusToAccountState() async throws {
        let active = SpiderAccountSessionPolicy.statusResolution(
            for: SpiderLoginStatusResponse(
                authenticated: true,
                entitlementStatus: "active",
                stripeCustomerId: "cus_test"
            )
        )
        let trial = SpiderAccountSessionPolicy.statusResolution(
            for: SpiderLoginStatusResponse(
                authenticated: true,
                entitlementStatus: "trial",
                stripeCustomerId: nil
            )
        )
        let canceled = SpiderAccountSessionPolicy.statusResolution(
            for: SpiderLoginStatusResponse(
                authenticated: true,
                entitlementStatus: "canceled",
                stripeCustomerId: nil
            )
        )
        let unknown = SpiderAccountSessionPolicy.statusResolution(
            for: SpiderLoginStatusResponse(
                authenticated: true,
                entitlementStatus: "past_due",
                stripeCustomerId: nil
            )
        )

        #expect(active.accountState == .active)
        #expect(active.loginStatusMessage == "Spider account active.")
        #expect(trial.accountState == .trial)
        #expect(canceled.accountState == .paymentRequired)
        #expect(canceled.loginStatusMessage == "Payment required before Spider can use AI.")
        #expect(unknown.accountState == .paymentRequired)
        #expect(unknown.loginStatusMessage == "Subscription status needs attention.")
    }

    @Test func parsesOnlyStrictSpiderMagicLinks() async throws {
        let validToken = "00000000-0000-4000-8000-00000000000100000000-0000-4000-8000-000000000002"
        let validURL = try #require(URL(string: "spider://auth/confirm?token=\(validToken)"))
        let extraQueryURL = try #require(URL(string: "spider://auth/confirm?token=\(validToken)&next=https://evil.test"))
        let wrongHostURL = try #require(URL(string: "spider://billing/confirm?token=\(validToken)"))
        let malformedTokenURL = try #require(URL(string: "spider://auth/confirm?token=not-a-token"))

        #expect(SpiderAccountSessionPolicy.magicLinkToken(from: validURL) == validToken)
        #expect(SpiderAccountSessionPolicy.magicLinkToken(from: extraQueryURL) == nil)
        #expect(SpiderAccountSessionPolicy.magicLinkToken(from: wrongHostURL) == nil)
        #expect(SpiderAccountSessionPolicy.magicLinkToken(from: malformedTokenURL) == nil)
    }

    @Test func keepsWorkerErrorHandlingStatusBased() async throws {
        let expired = SpiderWorkerClientError(statusCode: 401, operation: "test")
        let paymentRequired = SpiderWorkerClientError(statusCode: 402, operation: "test")
        let rateLimited = SpiderWorkerClientError(statusCode: 429, operation: "test")
        let conflict = SpiderWorkerClientError(statusCode: 409, operation: "billing")

        #expect(
            SpiderAccountSessionPolicy.workerErrorResolution(for: expired)
                == .loggedOut(
                    message: "Your Spider session expired. Sign in again.",
                    clearStoredToken: true,
                    shouldShowPanel: true
                )
        )
        #expect(
            SpiderAccountSessionPolicy.workerErrorResolution(for: paymentRequired)
                == .paymentRequired(
                    message: "Payment required before Spider can use AI.",
                    shouldShowPanel: true
                )
        )
        #expect(
            SpiderAccountSessionPolicy.workerErrorResolution(for: rateLimited)
                == .rateLimited(message: "Spider usage limit reached. Try again later.")
        )
        #expect(
            SpiderAccountSessionPolicy.billingFailureMessage(for: conflict, action: .checkout)
                == "Subscription is already active. Use the billing portal."
        )
    }
}
