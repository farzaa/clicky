//
//  CompanionAuthPresentationPolicyTests.swift
//  leanring-buddyTests
//
//  Keeps auth handoff copy and diagnostics typed.
//

import Testing
@testable import Spider

@MainActor
struct CompanionAuthPresentationPolicyTests {
    @Test func magicLinkStartPresentationKeepsExistingCopyAndTypedDiagnostic() {
        #expect(
            CompanionAuthPresentationPolicy.magicLinkStart == .init(
                invalidEmailMessage: "Enter a valid email address.",
                sendingMessage: "Sending magic link...",
                successMessage: "Check your email for the Spider login link.",
                failureMessage: "Could not send the login link. Check the Worker URL and try again.",
                failureDiagnosticEvent: .authStartFailed
            )
        )
    }

    @Test func magicLinkConfirmationPresentationKeepsExistingCopyAndTypedDiagnostic() {
        #expect(
            CompanionAuthPresentationPolicy.magicLinkConfirmation == .init(
                inProgressMessage: "Completing Spider login...",
                successMessage: "Spider login complete.",
                failureMessage: "That login link is invalid or expired.",
                failureDiagnosticEvent: .magicLinkConfirmationFailed
            )
        )
    }

    @Test func loginStatusPresentationKeepsExistingCopyAndState() {
        #expect(
            CompanionAuthPresentationPolicy.invalidDeepLinkMessage
                == "Spider could not understand that login link."
        )
        #expect(CompanionAuthPresentationPolicy.missingSessionMessage == "Sign in to continue.")
        #expect(
            CompanionAuthPresentationPolicy.workerVerificationFailureMessage
                == "Spider could not verify your account."
        )
        #expect(
            CompanionAuthPresentationPolicy.unexpectedLoginStatusFailure == .init(
                accountState: .error("Could not verify account."),
                loginStatusMessage: "Spider could not verify your account. Check your connection.",
                diagnosticEvent: .loginStatusFailed
            )
        )
    }
}
