//
//  CompanionManagerAccountActions.swift
//  leanring-buddy
//
//  Account, entitlement, and hosted Stripe handoffs for CompanionManager.
//  Screen guidance stays in CompanionManager; auth request shape stays in
//  SpiderAuthClient; policy decisions stay in SpiderAccountSessionPolicy.
//

import AppKit
import Foundation

@MainActor
extension CompanionManager {
    /// Starts Worker-backed magic-link login. Email is kept out of analytics and
    /// local persistence; the returned session token is stored in Keychain only
    /// after the user opens the magic link.
    func submitEmail(_ email: String) {
        let presentation = CompanionAuthPresentationPolicy.magicLinkStart
        guard !isSubmittingLogin else { return }
        guard let normalizedEmail = SpiderEmailAddressValidator.normalizedEmail(email) else {
            setLoginStatusMessage(presentation.invalidEmailMessage)
            return
        }

        CompanionAccountLocalStateStore.clearPendingEmail()
        setLoginRequestInFlight(true)
        setLoginStatusMessage(presentation.sendingMessage)

        Task { [weak self] in
            guard let self else { return }
            defer { setLoginRequestInFlight(false) }

            do {
                _ = try await spiderAuthClient.startMagicLinkLogin(email: normalizedEmail)
                setSubmittedEmailState(true)
                setLoginStatusMessage(presentation.successMessage)
            } catch {
                setSubmittedEmailState(false)
                setLoginStatusMessage(presentation.failureMessage)
                SpiderDiagnostics.event(presentation.failureDiagnosticEvent.message)
            }
        }
    }

    func handleDeepLink(_ url: URL) {
        if let token = SpiderAccountSessionPolicy.magicLinkToken(from: url) {
            confirmMagicLink(token: token)
            return
        }

        setLoginStatusMessage(CompanionAuthPresentationPolicy.invalidDeepLinkMessage)
    }

    func refreshLoginStatus() {
        guard SpiderConfiguration.sessionBearerToken != nil else {
            markLoggedOut(
                message: CompanionAuthPresentationPolicy.missingSessionMessage,
                clearStoredToken: false
            )
            return
        }

        setAccountState(.checking)
        Task { [weak self] in
            guard let self else { return }

            do {
                let status = try await spiderAuthClient.loginStatus()
                applyAccountStatusResolution(SpiderAccountSessionPolicy.statusResolution(for: status))
            } catch let workerError as SpiderWorkerClientError {
                handleWorkerClientError(workerError)
                if workerError.isAuthenticationExpired {
                    setLoginStatusMessage("Your Spider session expired. Sign in again.")
                } else {
                    setAccountState(
                        .error(SpiderAccountSessionPolicy.accountVerificationFailureMessage(for: workerError))
                    )
                    setLoginStatusMessage(CompanionAuthPresentationPolicy.workerVerificationFailureMessage)
                }
                SpiderDiagnostics.workerFailure("login status", statusCode: workerError.statusCode)
            } catch SpiderAuthClientError.missingSessionToken {
                markLoggedOut(
                    message: CompanionAuthPresentationPolicy.missingSessionMessage,
                    clearStoredToken: false
                )
            } catch {
                let presentation = CompanionAuthPresentationPolicy.unexpectedLoginStatusFailure
                setAccountState(presentation.accountState)
                setLoginStatusMessage(presentation.loginStatusMessage)
                SpiderDiagnostics.event(presentation.diagnosticEvent.message)
            }
        }
    }

    private func confirmMagicLink(token: String) {
        let presentation = CompanionAuthPresentationPolicy.magicLinkConfirmation
        setAccountState(.checking)
        setLoginStatusMessage(presentation.inProgressMessage)

        Task { [weak self] in
            guard let self else { return }

            do {
                _ = try await spiderAuthClient.confirmMagicLink(token: token)
                setSubmittedEmailState(true)
                setLoginStatusMessage(presentation.successMessage)
                refreshLoginStatus()
            } catch {
                setAccountState(.loggedOut)
                setLoginStatusMessage(presentation.failureMessage)
                SpiderDiagnostics.event(presentation.failureDiagnosticEvent.message)
            }
        }
    }

    func openCheckout() {
        guard !isOpeningCheckout else { return }
        let presentation = CompanionBillingPresentationPolicy.presentation(for: .checkout)
        setCheckoutRequestInFlight(true)
        setBillingStatusMessage(presentation.openingMessage)
        Task { [weak self] in
            guard let self else { return }
            defer { setCheckoutRequestInFlight(false) }

            do {
                let checkoutSession = try await spiderAuthClient.createCheckoutSession()
                NSWorkspace.shared.open(checkoutSession.url)
                setBillingStatusMessage(presentation.openedMessage)
            } catch let workerError as SpiderWorkerClientError {
                handleWorkerClientError(workerError)
                setBillingStatusMessage(
                    SpiderAccountSessionPolicy.billingFailureMessage(
                        for: workerError,
                        action: .checkout
                    )
                )
                SpiderDiagnostics.workerFailure("checkout", statusCode: workerError.statusCode)
            } catch {
                setBillingStatusMessage(presentation.fallbackFailureMessage)
                SpiderDiagnostics.event(presentation.failureDiagnosticEvent.message)
            }
        }
    }

    func openBillingPortal() {
        guard !isOpeningBillingPortal else { return }
        let presentation = CompanionBillingPresentationPolicy.presentation(for: .portal)
        setBillingPortalRequestInFlight(true)
        setBillingStatusMessage(presentation.openingMessage)
        Task { [weak self] in
            guard let self else { return }
            defer { setBillingPortalRequestInFlight(false) }

            do {
                let billingPortalSession = try await spiderAuthClient.createBillingPortalSession()
                NSWorkspace.shared.open(billingPortalSession.url)
                setBillingStatusMessage(presentation.openedMessage)
            } catch let workerError as SpiderWorkerClientError {
                handleWorkerClientError(workerError)
                setBillingStatusMessage(
                    SpiderAccountSessionPolicy.billingFailureMessage(
                        for: workerError,
                        action: .portal
                    )
                )
                SpiderDiagnostics.workerFailure("billing portal", statusCode: workerError.statusCode)
            } catch {
                setBillingStatusMessage(presentation.fallbackFailureMessage)
                SpiderDiagnostics.event(presentation.failureDiagnosticEvent.message)
            }
        }
    }

    func logout() {
        guard !isLoggingOut else { return }
        setLogoutRequestInFlight(true)
        Task { [weak self] in
            guard let self else { return }
            defer { setLogoutRequestInFlight(false) }

            do {
                _ = try await spiderAuthClient.revokeCurrentSession()
            } catch {
                SpiderDiagnostics.event("remote logout failed")
            }

            markLoggedOut(message: "Signed out.", clearStoredToken: true)
        }
    }

    func markLoggedOut(message: String, clearStoredToken: Bool) {
        if clearStoredToken {
            do {
                try spiderAuthClient.logout()
            } catch {
                SpiderDiagnostics.event("local logout failed")
            }
        }

        setAccountState(.loggedOut)
        setSubmittedEmailState(false)
        setLoginStatusMessage(message)
        setBillingStatusMessage(nil)
    }

    func handleWorkerClientError(_ error: SpiderWorkerClientError) {
        switch SpiderAccountSessionPolicy.workerErrorResolution(for: error) {
        case let .loggedOut(message, clearStoredToken, shouldShowPanel):
            markLoggedOut(message: message, clearStoredToken: clearStoredToken)
            if shouldShowPanel {
                NotificationCenter.default.post(name: .spiderShowPanel, object: nil)
            }
        case let .paymentRequired(message, shouldShowPanel):
            setAccountState(.paymentRequired)
            setLoginStatusMessage(message)
            if shouldShowPanel {
                NotificationCenter.default.post(name: .spiderShowPanel, object: nil)
            }
        case let .rateLimited(message):
            setLoginStatusMessage(message)
        case .unchanged:
            break
        }
    }

    func validateAIEntitlementBeforeScreenCapture() async throws {
        guard SpiderConfiguration.sessionBearerToken != nil else {
            markLoggedOut(message: "Sign in to continue.", clearStoredToken: false)
            throw SpiderWorkerClientError(statusCode: 401, operation: "pre_capture_entitlement")
        }

        let status = try await spiderAuthClient.loginStatus()
        let resolution = SpiderAccountSessionPolicy.statusResolution(for: status)
        applyAccountStatusResolution(resolution)

        guard resolution.accountState.canUseAI else {
            NotificationCenter.default.post(name: .spiderShowPanel, object: nil)
            throw SpiderWorkerClientError(statusCode: 402, operation: "pre_capture_entitlement")
        }
    }

    private func applyAccountStatusResolution(_ resolution: SpiderAccountStatusResolution) {
        setAccountState(resolution.accountState)
        setSubmittedEmailState(resolution.hasSubmittedEmail)
        setLoginStatusMessage(resolution.loginStatusMessage)
    }
}
