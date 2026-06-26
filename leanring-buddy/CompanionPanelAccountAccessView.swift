//
//  CompanionPanelAccountAccessView.swift
//  leanring-buddy
//
//  Account access controls for the menu bar panel.
//

import SwiftUI

struct CompanionPanelLoginForm: View {
    @ObservedObject var companionManager: CompanionManager
    @Binding var emailInput: String
    let appLanguage: SpiderAppLanguage

    var body: some View {
        let canSubmitEmail = normalizedLoginEmail != nil
        let isLoginButtonEnabled = canSubmitEmail && !companionManager.isSubmittingLogin

        return VStack(spacing: 10) {
            TextField(copy("Enter your email"), text: $emailInput)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(spiderTextPrimary)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(CompanionPanelSurface.assetCard)

            Button(action: {
                if let normalizedLoginEmail {
                    companionManager.submitEmail(normalizedLoginEmail)
                }
            }) {
                Text(companionManager.isSubmittingLogin ? copy("Sending...") : copy("Send magic link"))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.88))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(CompanionPanelSurface.signInPillBackground(isEnabled: isLoginButtonEnabled))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(!isLoginButtonEnabled)

            if let loginStatusMessage = companionManager.loginStatusMessage {
                Text(loginStatusMessage)
                    .font(DS.Typography.caption)
                    .foregroundStyle(spiderTextMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if companionManager.accountState == .paymentRequired {
                CompanionPanelBillingRequiredCard(
                    companionManager: companionManager,
                    appLanguage: appLanguage
                )
            }
        }
    }

    private var normalizedLoginEmail: String? {
        SpiderEmailAddressValidator.normalizedEmail(emailInput)
    }

    private var spiderTextPrimary: Color {
        DS.SpiderPanel.Colors.textPrimary
    }

    private var spiderTextMuted: Color {
        DS.SpiderPanel.Colors.textMuted
    }

    private func copy(_ key: String) -> String {
        SpiderPanelCopy.text(key, language: appLanguage)
    }
}

struct CompanionPanelBillingRequiredCard: View {
    @ObservedObject var companionManager: CompanionManager
    let appLanguage: SpiderAppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: {
                companionManager.openCheckout()
            }) {
                Text(companionManager.isOpeningCheckout ? copy("Opening checkout...") : copy("Upgrade to PRO"))
                    .font(DS.Typography.button)
                    .foregroundStyle(spiderDarkText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(CompanionPanelSurface.primaryPillBackground(isEnabled: !companionManager.isOpeningCheckout))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(companionManager.isOpeningCheckout)

            if let billingStatusMessage = companionManager.billingStatusMessage {
                Text(billingStatusMessage)
                    .font(DS.Typography.caption)
                    .foregroundStyle(spiderTextMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 4)
    }

    private var spiderDarkText: Color {
        DS.SpiderPanel.Colors.accentText
    }

    private var spiderTextMuted: Color {
        DS.SpiderPanel.Colors.textMuted
    }

    private func copy(_ key: String) -> String {
        SpiderPanelCopy.text(key, language: appLanguage)
    }
}
