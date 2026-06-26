//
//  CompanionBillingPresentationPolicy.swift
//  leanring-buddy
//
//  Local UI copy and diagnostics for hosted Stripe billing handoffs.
//

enum CompanionBillingPresentationPolicy {
    struct Presentation: Equatable {
        let openingMessage: String
        let openedMessage: String
        let fallbackFailureMessage: String
        let failureDiagnosticEvent: DiagnosticEvent
    }

    enum DiagnosticEvent: Equatable {
        case checkoutFailed
        case billingPortalFailed

        var message: StaticString {
            switch self {
            case .checkoutFailed:
                return "checkout failed"
            case .billingPortalFailed:
                return "billing portal failed"
            }
        }
    }

    static func presentation(for action: SpiderBillingAction) -> Presentation {
        switch action {
        case .checkout:
            return Presentation(
                openingMessage: "Opening checkout...",
                openedMessage: "Checkout opened in your browser.",
                fallbackFailureMessage: "Could not open checkout. Check Stripe config.",
                failureDiagnosticEvent: .checkoutFailed
            )
        case .portal:
            return Presentation(
                openingMessage: "Opening billing portal...",
                openedMessage: "Billing portal opened in your browser.",
                fallbackFailureMessage: "Could not open billing portal.",
                failureDiagnosticEvent: .billingPortalFailed
            )
        }
    }
}
