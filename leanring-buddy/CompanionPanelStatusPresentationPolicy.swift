//
//  CompanionPanelStatusPresentationPolicy.swift
//  leanring-buddy
//
//  Account and voice status presentation rules for the menu bar panel.
//

enum CompanionPanelStatusDotStyle {
    case inactive
    case success
    case accent
}

enum CompanionPanelStatusPresentationPolicy {
    static func shouldShowAccountGate(accountState: SpiderAccountState) -> Bool {
        !accountState.canUseAI
    }

    static func shouldShowPermissions(
        accountState: SpiderAccountState,
        allPermissionsGranted: Bool
    ) -> Bool {
        accountState.canUseAI && !allPermissionsGranted
    }

    static func shouldShowStartButton(
        accountState: SpiderAccountState,
        allPermissionsGranted: Bool,
        hasCompletedOnboarding: Bool
    ) -> Bool {
        accountState.canUseAI
            && allPermissionsGranted
            && !hasCompletedOnboarding
    }

    static func isReadyForGuidance(
        accountState: SpiderAccountState,
        allPermissionsGranted: Bool,
        hasCompletedOnboarding: Bool
    ) -> Bool {
        accountState.canUseAI
            && allPermissionsGranted
            && hasCompletedOnboarding
    }

    static func statusDotStyle(
        accountState: SpiderAccountState,
        isOverlayVisible: Bool,
        voiceState: CompanionVoiceState
    ) -> CompanionPanelStatusDotStyle {
        guard accountState.canUseAI, isOverlayVisible else {
            return .inactive
        }

        switch voiceState {
        case .idle:
            return .success
        case .listening, .processing, .responding:
            return .accent
        }
    }

    static func statusTextKey(
        accountState: SpiderAccountState,
        allPermissionsGranted: Bool,
        hasCompletedOnboarding: Bool,
        isOverlayVisible: Bool,
        voiceState: CompanionVoiceState
    ) -> String {
        if !accountState.canUseAI {
            switch accountState {
            case .loggedOut:
                return "Sign in"
            case .checking:
                return "Checking"
            case .paymentRequired:
                return "Billing"
            case .error:
                return "Account"
            case .active, .trial:
                break
            }
        }
        if !allPermissionsGranted {
            return "Setup"
        }
        if !hasCompletedOnboarding {
            return "Setup"
        }
        if !isOverlayVisible {
            return "Ready"
        }

        switch voiceState {
        case .idle:
            return "Active"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .responding:
            return "Responding"
        }
    }

    static func accountSetupTitleKey(for accountState: SpiderAccountState) -> String {
        switch accountState {
        case .loggedOut, .error:
            return "Sign in"
        case .checking:
            return "Checking account"
        case .paymentRequired:
            return "Subscription required"
        case .active, .trial:
            return "Account ready"
        }
    }

    static func accountSetupCopyKey(for accountState: SpiderAccountState) -> String {
        switch accountState {
        case .loggedOut, .error:
            return "Spider sends a magic link. No password, no client-side API key nonsense."
        case .checking:
            return "Spider is verifying your session and subscription."
        case .paymentRequired:
            return "Beta access is paid. Spider cannot run screen guidance or Realtime voice without an active subscription."
        case .active:
            return "Your subscription is active."
        case .trial:
            return "Your trial is active."
        }
    }
}
