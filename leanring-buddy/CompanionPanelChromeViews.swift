//
//  CompanionPanelChromeViews.swift
//  leanring-buddy
//
//  Reusable chrome and account-plan sections for the Spider menu bar panel.
//

import SwiftUI

struct CompanionPanelBrandHeader: View {
    let appLanguage: SpiderAppLanguage
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            HStack {
                Text("SpiderAds")
                    .font(DS.Typography.rowBody)
                    .foregroundStyle(spiderAccent)

                Spacer()
            }
            .frame(minHeight: 28)
            .panelDragHandle()

            CompanionPanelHeaderActionButtons(
                appLanguage: appLanguage,
                onOpenSettings: onOpenSettings,
                onQuit: onQuit
            )
        }
    }
}

struct CompanionPanelWizardHeader: View {
    let title: String
    let appLanguage: SpiderAppLanguage
    let onBack: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        HStack {
            CompanionPanelCircularIconButton(systemName: "chevron.left", action: onBack)

            HStack {
                Spacer()

                Text(title)
                    .font(DS.Typography.panelHeader)
                    .foregroundStyle(spiderAccent)

                Spacer()
            }
            .frame(minHeight: 32)
            .panelDragHandle()

            CompanionPanelHeaderActionButtons(
                appLanguage: appLanguage,
                onOpenSettings: onOpenSettings,
                onQuit: onQuit
            )
        }
    }
}

struct CompanionPanelHeaderActionButtons: View {
    let appLanguage: SpiderAppLanguage
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            CompanionPanelCircularIconButton(systemName: "slider.horizontal.3", action: onOpenSettings)

            CompanionPanelCircularIconButton(systemName: "xmark", action: onQuit)
                .help(copy("Quit Spider"))
        }
    }

    private func copy(_ key: String) -> String {
        SpiderPanelCopy.text(key, language: appLanguage)
    }
}

struct CompanionPanelHomePrimaryAction: View {
    let appLanguage: SpiderAppLanguage
    let onStart: () -> Void

    var body: some View {
        let isGuidedSetupAvailable = SpiderProductFeatures.isAvailable(.firstStepGuidedSetup)

        return Button(action: {
            guard isGuidedSetupAvailable else { return }
            onStart()
        }) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(copy("Build from Scratch"))
                        .font(DS.Typography.rowTitle)
                        .foregroundStyle(spiderTextPrimary)

                    Text(copy("Start with your offer."))
                        .font(DS.Typography.rowBody)
                        .foregroundStyle(spiderTextMuted)
                }

                Spacer()

                Text(copy("Start"))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(spiderDarkText)
                    .frame(width: 84, height: 40)
                    .background(CompanionPanelSurface.primaryPillBackground(isEnabled: isGuidedSetupAvailable))
            }
            .padding(.horizontal, 18)
            .frame(height: 86)
            .background(CompanionPanelSurface.primaryActionCard)
        }
        .buttonStyle(.plain)
        .disabled(!isGuidedSetupAvailable)
        .opacity(isGuidedSetupAvailable ? 1 : 0.52)
        .pointerCursor(isEnabled: isGuidedSetupAvailable)
    }

    private func copy(_ key: String) -> String {
        SpiderPanelCopy.text(key, language: appLanguage)
    }
}

struct CompanionPanelPlanCard: View {
    @ObservedObject var companionManager: CompanionManager
    let appLanguage: SpiderAppLanguage

    var body: some View {
        VStack(spacing: 10) {
            Text(copy("Plan"))
                .font(DS.Typography.rowTitle)
                .foregroundStyle(spiderTextPrimary)

            Text(copy("Free · 1 campaign left"))
                .font(DS.Typography.rowBody)
                .foregroundStyle(spiderTextMuted)

            Button(action: {
                companionManager.openCheckout()
            }) {
                Text(copy("Upgrade to PRO"))
                    .font(DS.Typography.button)
                    .foregroundStyle(spiderDarkText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(CompanionPanelSurface.primaryPillBackground(isEnabled: !companionManager.isOpeningCheckout))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(companionManager.isOpeningCheckout)

            VStack(spacing: 6) {
                Text(copy("Unlimited guided campaigns"))
                ForEach(SpiderProductFeatures.planFeatureDescriptors, id: \.feature) { featureDescriptor in
                    Text(copy(featureDescriptor.planLineCopyKey))
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(spiderTextMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
        .background(CompanionPanelSurface.primaryActionCard)
    }

    private func copy(_ key: String) -> String {
        SpiderPanelCopy.text(key, language: appLanguage)
    }
}

struct CompanionPanelSettingsFooter: View {
    let appLanguage: SpiderAppLanguage

    var body: some View {
        HStack {
            Text("SpiderAds 1.0")
            Spacer()
            Text(copy("Terms · Privacy Policy"))
        }
        .font(DS.Typography.caption)
        .foregroundStyle(spiderTextFaint.opacity(0.7))
    }

    private func copy(_ key: String) -> String {
        SpiderPanelCopy.text(key, language: appLanguage)
    }
}

private var spiderAccent: Color {
    DS.SpiderPanel.Colors.accent
}

private var spiderDarkText: Color {
    DS.SpiderPanel.Colors.accentText
}

private var spiderTextPrimary: Color {
    DS.SpiderPanel.Colors.textPrimary
}

private var spiderTextMuted: Color {
    DS.SpiderPanel.Colors.textMuted
}

private var spiderTextFaint: Color {
    DS.SpiderPanel.Colors.textFaint
}
