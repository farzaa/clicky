//
//  CompanionAuthPresentationPolicy.swift
//  leanring-buddy
//
//  Local UI copy and diagnostics for auth handoffs. Network requests stay in
//  SpiderAuthClient; session rules stay in SpiderAccountSessionPolicy.
//

enum CompanionAuthPresentationPolicy {
    struct MagicLinkStartPresentation: Equatable {
        let invalidEmailMessage: String
        let sendingMessage: String
        let successMessage: String
        let failureMessage: String
        let failureDiagnosticEvent: DiagnosticEvent
    }

    struct MagicLinkConfirmationPresentation: Equatable {
        let inProgressMessage: String
        let successMessage: String
        let failureMessage: String
        let failureDiagnosticEvent: DiagnosticEvent
    }

    struct LoginStatusUnexpectedFailurePresentation: Equatable {
        let accountState: SpiderAccountState
        let loginStatusMessage: String
        let diagnosticEvent: DiagnosticEvent
    }

    enum DiagnosticEvent: Equatable {
        case authStartFailed
        case magicLinkConfirmationFailed
        case loginStatusFailed

        var message: StaticString {
            switch self {
            case .authStartFailed:
                return "auth start failed"
            case .magicLinkConfirmationFailed:
                return "magic-link confirmation failed"
            case .loginStatusFailed:
                return "login status failed"
            }
        }
    }

    static let magicLinkStart = MagicLinkStartPresentation(
        invalidEmailMessage: "Enter a valid email address.",
        sendingMessage: "Sending magic link...",
        successMessage: "Check your email for the Spider login link.",
        failureMessage: "Could not send the login link. Check the Worker URL and try again.",
        failureDiagnosticEvent: .authStartFailed
    )

    static let magicLinkConfirmation = MagicLinkConfirmationPresentation(
        inProgressMessage: "Completing Spider login...",
        successMessage: "Spider login complete.",
        failureMessage: "That login link is invalid or expired.",
        failureDiagnosticEvent: .magicLinkConfirmationFailed
    )

    static let invalidDeepLinkMessage = "Spider could not understand that login link."
    static let missingSessionMessage = "Sign in to continue."
    static let workerVerificationFailureMessage = "Spider could not verify your account."

    static let unexpectedLoginStatusFailure = LoginStatusUnexpectedFailurePresentation(
        accountState: .error("Could not verify account."),
        loginStatusMessage: "Spider could not verify your account. Check your connection.",
        diagnosticEvent: .loginStatusFailed
    )
}
