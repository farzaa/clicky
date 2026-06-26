//
//  CompanionBillingPresentationPolicyTests.swift
//  leanring-buddyTests
//
//  Keeps hosted billing handoff copy and diagnostics typed.
//

import Testing
@testable import Spider

@MainActor
struct CompanionBillingPresentationPolicyTests {
    @Test func checkoutPresentationKeepsExistingCopyAndTypedDiagnostic() {
        #expect(
            CompanionBillingPresentationPolicy.presentation(for: .checkout) == .init(
                openingMessage: "Opening checkout...",
                openedMessage: "Checkout opened in your browser.",
                fallbackFailureMessage: "Could not open checkout. Check Stripe config.",
                failureDiagnosticEvent: .checkoutFailed
            )
        )
    }

    @Test func portalPresentationKeepsExistingCopyAndTypedDiagnostic() {
        #expect(
            CompanionBillingPresentationPolicy.presentation(for: .portal) == .init(
                openingMessage: "Opening billing portal...",
                openedMessage: "Billing portal opened in your browser.",
                fallbackFailureMessage: "Could not open billing portal.",
                failureDiagnosticEvent: .billingPortalFailed
            )
        )
    }
}
