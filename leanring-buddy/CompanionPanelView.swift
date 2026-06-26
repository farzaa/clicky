//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the companion
//  voice status, push-to-talk shortcut, and quick settings. Designed to feel
//  like Loom's recording panel — dark, rounded, minimal, and special.
//

import AppKit
import SwiftUI

private enum SpiderPanelWorkflowMode {
    case home
    case offer
    case campaignGoal
    case audience
    case testLimit
    case campaignReady
    case settings
    case settingsGeneral
    case settingsPermissions
}

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @AppStorage(SpiderUserPreferenceKey.appLanguage) private var appLanguageRawValue: String = SpiderAppLanguage.english.rawValue
    @State private var emailInput: String = ""
    @State private var workflowMode: SpiderPanelWorkflowMode = .home
    @State private var missionDraft = CompanionPanelMissionDraft()

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                panelChrome
            }
        } else {
            panelChrome
        }
    }

    private var appLanguage: SpiderAppLanguage {
        SpiderAppLanguage.normalized(appLanguageRawValue)
    }

    private func copy(_ key: String) -> String {
        SpiderPanelCopy.text(key, language: appLanguage)
    }

    private var panelChrome: some View {
        let shape = RoundedRectangle(cornerRadius: DS.SpiderPanel.Radius.chrome, style: .continuous)
        let primaryShadow = DS.SpiderPanel.Shadows.chromePrimary
        let secondaryShadow = DS.SpiderPanel.Shadows.chromeSecondary

        return panelContent
            .frame(width: DS.SpiderPanel.Layout.contentWidth, alignment: .leading)
            .padding(DS.SpiderPanel.Layout.padding)
            .frame(width: DS.SpiderPanel.Layout.width)
            .companionPanelLiquidGlass(in: shape, tint: DS.SpiderPanel.Colors.chromeTint)
            .overlay(CompanionPanelSurface.panelHighlight(in: shape))
            .clipShape(shape)
            .shadow(
                color: primaryShadow.color,
                radius: primaryShadow.radius,
                x: primaryShadow.x,
                y: primaryShadow.y
            )
            .shadow(
                color: secondaryShadow.color,
                radius: secondaryShadow.radius,
                x: secondaryShadow.x,
                y: secondaryShadow.y
            )
    }

    // MARK: - Asset-Matched Flow

    @ViewBuilder
    private var panelContent: some View {
        switch workflowMode {
        case .settings:
            settingsPanel
        case .settingsGeneral:
            settingsGeneralPanel
        case .settingsPermissions:
            settingsPermissionsPanel
        default:
            if shouldShowAccountGate {
                signupPanel
            } else {
                switch workflowMode {
                case .home:
                    homePanel
                case .offer:
                    offerPanel
                case .campaignGoal:
                    campaignGoalPanel
                case .audience:
                    audiencePanel
                case .testLimit:
                    testLimitPanel
                case .campaignReady:
                    campaignReadyPanel
                case .settings, .settingsGeneral, .settingsPermissions:
                    EmptyView()
                }
            }
        }
    }

    private var homePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            brandHeader

            VStack(alignment: .leading, spacing: 8) {
                Text(copy("Build the right campaign\nbefore you spend."))
                    .font(DS.Typography.panelTitle)
                    .foregroundStyle(spiderTextPrimary)
                    .lineSpacing(-1)

                Text(copy("Spider shows what to click, what to avoid,\nand when to stop before you spend."))
                    .font(DS.Typography.rowBody)
                    .foregroundStyle(spiderTextMuted)
                    .lineSpacing(1)
            }

            VStack(spacing: 12) {
                CompanionPanelHomePrimaryAction(appLanguage: appLanguage) {
                    prefillOfferFormFromMission()
                    workflowMode = .offer
                }
            }
        }
    }

    private var signupPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            brandHeader

            VStack(alignment: .leading, spacing: 4) {
                Text(copy("Build the right campaign\nbefore you spend."))
                    .font(DS.Typography.panelTitle)
                    .foregroundStyle(spiderTextPrimary)
                    .lineSpacing(-1)

                Text(copy("Spider shows what to click, what to avoid,\nand when to stop before you spend."))
                    .font(DS.Typography.rowBody)
                    .foregroundStyle(spiderTextMuted)
                    .lineSpacing(1)
            }

            CompanionPanelLoginForm(
                companionManager: companionManager,
                emailInput: $emailInput,
                appLanguage: appLanguage
            )
        }
    }

    private var offerPanel: some View {
        CompanionPanelOfferStepView(
            appLanguage: appLanguage,
            missionDraft: $missionDraft,
            onBack: { workflowMode = .home },
            onNext: { workflowMode = .campaignGoal },
            onOpenSettings: openSettings,
            onQuit: quitSpiderApp
        )
    }

    private var campaignGoalPanel: some View {
        CompanionPanelCampaignGoalStepView(
            appLanguage: appLanguage,
            missionDraft: $missionDraft,
            onBack: { workflowMode = .offer },
            onNext: { workflowMode = .audience },
            onOpenSettings: openSettings,
            onQuit: quitSpiderApp
        )
    }

    private var audiencePanel: some View {
        CompanionPanelAudienceStepView(
            appLanguage: appLanguage,
            missionDraft: $missionDraft,
            onBack: { workflowMode = .campaignGoal },
            onNext: { workflowMode = .testLimit },
            onOpenSettings: openSettings,
            onQuit: quitSpiderApp
        )
    }

    private var testLimitPanel: some View {
        CompanionPanelTestLimitStepView(
            appLanguage: appLanguage,
            missionDraft: $missionDraft,
            onBack: { workflowMode = .audience },
            onNext: {
                createAdMissionFromWizard()
                workflowMode = .campaignReady
            },
            onOpenSettings: openSettings,
            onQuit: quitSpiderApp
        )
    }

    private var campaignReadyPanel: some View {
        CompanionPanelCampaignReadyStepView(
            appLanguage: appLanguage,
            missionDraft: missionDraft,
            onBack: { workflowMode = .testLimit },
            onGuide: {
                createAdMissionFromWizard()
                runScreenActionOrOpenPermissions {
                    companionManager.openConfiguredAdPlatformAndStartGuidedSetup()
                }
            },
            onOpenSettings: openSettings,
            onQuit: quitSpiderApp
        )
    }

    private var settingsPanel: some View {
        CompanionPanelSettingsHomeView(
            companionManager: companionManager,
            appLanguage: appLanguage,
            onBack: { workflowMode = .home },
            onOpenGeneral: { workflowMode = .settingsGeneral },
            onOpenPermissions: { workflowMode = .settingsPermissions },
            onOpenSettings: openSettings,
            onQuit: quitSpiderApp
        )
    }

    private var settingsGeneralPanel: some View {
        CompanionPanelSettingsGeneralView(
            appLanguage: appLanguage,
            appLanguageRawValue: $appLanguageRawValue,
            missionDraft: $missionDraft,
            onBack: { workflowMode = .settings },
            onOpenSettings: openSettings,
            onQuit: quitSpiderApp
        )
    }

    private var settingsPermissionsPanel: some View {
        CompanionPanelSettingsPermissionsView(
            companionManager: companionManager,
            appLanguage: appLanguage,
            onBack: { workflowMode = .settings },
            onOpenSettings: openSettings,
            onQuit: quitSpiderApp
        )
    }

    private var brandHeader: some View {
        CompanionPanelBrandHeader(
            appLanguage: appLanguage,
            onOpenSettings: openSettings,
            onQuit: quitSpiderApp
        )
    }

    private func openSettings() {
        workflowMode = .settings
    }

    private func quitSpiderApp() {
        companionManager.stop()
        NSApp.terminate(nil)
    }

    private var spiderTextPrimary: Color {
        DS.SpiderPanel.Colors.textPrimary
    }

    private var spiderTextMuted: Color {
        DS.SpiderPanel.Colors.textMuted
    }

    private func prefillOfferFormFromMission() {
        missionDraft.prefill(from: companionManager.adMission)
    }

    private func createAdMissionFromWizard() {
        companionManager.startAdMissionFromOffer(missionDraft.adMissionOfferDraft())
    }

    private func runScreenActionOrOpenPermissions(_ action: () -> Void) {
        companionManager.refreshAllPermissions()

        guard WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch() else {
            WindowPositionManager.requestScreenRecordingPermission()
            return
        }

        guard companionManager.hasScreenContentPermission else {
            companionManager.requestScreenContentPermission()
            return
        }

        action()
    }

    // MARK: - Visual Helpers

    private var shouldShowAccountGate: Bool {
        CompanionPanelStatusPresentationPolicy.shouldShowAccountGate(
            accountState: companionManager.accountState
        )
    }

}
