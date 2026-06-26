//
//  CompanionPanelStatusPresentationPolicyTests.swift
//  leanring-buddyTests
//
//  Locks menu bar panel status and account gate presentation outside SwiftUI.
//

import Testing
@testable import Spider

struct CompanionPanelStatusPresentationPolicyTests {
    @Test func accountGateAndReadinessKeepExistingPermissionOrder() {
        #expect(CompanionPanelStatusPresentationPolicy.shouldShowAccountGate(accountState: .loggedOut))
        #expect(CompanionPanelStatusPresentationPolicy.shouldShowAccountGate(accountState: .paymentRequired))
        #expect(!CompanionPanelStatusPresentationPolicy.shouldShowAccountGate(accountState: .active))
        #expect(!CompanionPanelStatusPresentationPolicy.shouldShowAccountGate(accountState: .trial))

        #expect(CompanionPanelStatusPresentationPolicy.shouldShowPermissions(
            accountState: .active,
            allPermissionsGranted: false
        ))
        #expect(!CompanionPanelStatusPresentationPolicy.shouldShowPermissions(
            accountState: .loggedOut,
            allPermissionsGranted: false
        ))

        #expect(CompanionPanelStatusPresentationPolicy.shouldShowStartButton(
            accountState: .trial,
            allPermissionsGranted: true,
            hasCompletedOnboarding: false
        ))
        #expect(!CompanionPanelStatusPresentationPolicy.shouldShowStartButton(
            accountState: .trial,
            allPermissionsGranted: true,
            hasCompletedOnboarding: true
        ))

        #expect(CompanionPanelStatusPresentationPolicy.isReadyForGuidance(
            accountState: .active,
            allPermissionsGranted: true,
            hasCompletedOnboarding: true
        ))
        #expect(!CompanionPanelStatusPresentationPolicy.isReadyForGuidance(
            accountState: .paymentRequired,
            allPermissionsGranted: true,
            hasCompletedOnboarding: true
        ))
    }

    @Test func statusDotStyleKeepsAccountAndOverlayGatesBeforeVoiceState() {
        #expect(isStyle(CompanionPanelStatusPresentationPolicy.statusDotStyle(
            accountState: .paymentRequired,
            isOverlayVisible: true,
            voiceState: .idle
        ), .inactive))
        #expect(isStyle(CompanionPanelStatusPresentationPolicy.statusDotStyle(
            accountState: .active,
            isOverlayVisible: false,
            voiceState: .idle
        ), .inactive))
        #expect(isStyle(CompanionPanelStatusPresentationPolicy.statusDotStyle(
            accountState: .active,
            isOverlayVisible: true,
            voiceState: .idle
        ), .success))
        #expect(isStyle(CompanionPanelStatusPresentationPolicy.statusDotStyle(
            accountState: .active,
            isOverlayVisible: true,
            voiceState: .listening
        ), .accent))
        #expect(isStyle(CompanionPanelStatusPresentationPolicy.statusDotStyle(
            accountState: .active,
            isOverlayVisible: true,
            voiceState: .processing
        ), .accent))
        #expect(isStyle(CompanionPanelStatusPresentationPolicy.statusDotStyle(
            accountState: .active,
            isOverlayVisible: true,
            voiceState: .responding
        ), .accent))
    }

    @Test func statusTextKeysKeepExistingPriorityAndCopyKeys() {
        #expect(statusTextKey(accountState: .loggedOut) == "Sign in")
        #expect(statusTextKey(accountState: .checking) == "Checking")
        #expect(statusTextKey(accountState: .paymentRequired) == "Billing")
        #expect(statusTextKey(accountState: .error("Nope")) == "Account")

        #expect(statusTextKey(allPermissionsGranted: false) == "Setup")
        #expect(statusTextKey(hasCompletedOnboarding: false) == "Setup")
        #expect(statusTextKey(isOverlayVisible: false) == "Ready")
        #expect(statusTextKey(voiceState: .idle) == "Active")
        #expect(statusTextKey(voiceState: .listening) == "Listening")
        #expect(statusTextKey(voiceState: .processing) == "Processing")
        #expect(statusTextKey(voiceState: .responding) == "Responding")
    }

    @Test func accountSetupCopyKeysKeepExistingAccountMessages() {
        #expect(CompanionPanelStatusPresentationPolicy.accountSetupTitleKey(for: .loggedOut) == "Sign in")
        #expect(CompanionPanelStatusPresentationPolicy.accountSetupTitleKey(for: .error("Nope")) == "Sign in")
        #expect(CompanionPanelStatusPresentationPolicy.accountSetupTitleKey(for: .checking) == "Checking account")
        #expect(CompanionPanelStatusPresentationPolicy.accountSetupTitleKey(for: .paymentRequired) == "Subscription required")
        #expect(CompanionPanelStatusPresentationPolicy.accountSetupTitleKey(for: .active) == "Account ready")
        #expect(CompanionPanelStatusPresentationPolicy.accountSetupTitleKey(for: .trial) == "Account ready")

        #expect(CompanionPanelStatusPresentationPolicy.accountSetupCopyKey(for: .loggedOut) == "Spider sends a magic link. No password, no client-side API key nonsense.")
        #expect(CompanionPanelStatusPresentationPolicy.accountSetupCopyKey(for: .error("Nope")) == "Spider sends a magic link. No password, no client-side API key nonsense.")
        #expect(CompanionPanelStatusPresentationPolicy.accountSetupCopyKey(for: .checking) == "Spider is verifying your session and subscription.")
        #expect(CompanionPanelStatusPresentationPolicy.accountSetupCopyKey(for: .paymentRequired) == "Beta access is paid. Spider cannot run screen guidance or Realtime voice without an active subscription.")
        #expect(CompanionPanelStatusPresentationPolicy.accountSetupCopyKey(for: .active) == "Your subscription is active.")
        #expect(CompanionPanelStatusPresentationPolicy.accountSetupCopyKey(for: .trial) == "Your trial is active.")
    }

    private func statusTextKey(
        accountState: SpiderAccountState = .active,
        allPermissionsGranted: Bool = true,
        hasCompletedOnboarding: Bool = true,
        isOverlayVisible: Bool = true,
        voiceState: CompanionVoiceState = .idle
    ) -> String {
        CompanionPanelStatusPresentationPolicy.statusTextKey(
            accountState: accountState,
            allPermissionsGranted: allPermissionsGranted,
            hasCompletedOnboarding: hasCompletedOnboarding,
            isOverlayVisible: isOverlayVisible,
            voiceState: voiceState
        )
    }

    private func isStyle(
        _ actual: CompanionPanelStatusDotStyle,
        _ expected: CompanionPanelStatusDotStyle
    ) -> Bool {
        switch (actual, expected) {
        case (.inactive, .inactive), (.success, .success), (.accent, .accent):
            return true
        default:
            return false
        }
    }
}
