//
//  CompanionPanelSettingsViews.swift
//  leanring-buddy
//
//  Settings and permission panels for the Spider menu bar panel.
//

import AVFoundation
import AppKit
import SwiftUI

struct CompanionPanelSettingsHomeView: View {
    @ObservedObject var companionManager: CompanionManager
    let appLanguage: SpiderAppLanguage
    let onBack: () -> Void
    let onOpenGeneral: () -> Void
    let onOpenPermissions: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            wizardHeader(title: copy("Settings"), onBack: onBack)

            VStack(spacing: 0) {
                CompanionPanelSettingsNavigationRow(title: copy("Permissions"), action: onOpenPermissions)
                CompanionPanelSurface.assetDivider
                CompanionPanelSettingsNavigationRow(title: copy("General"), action: onOpenGeneral)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .background(CompanionPanelSurface.assetCard)

            CompanionPanelPlanCard(
                companionManager: companionManager,
                appLanguage: appLanguage
            )

            settingsFooter
        }
    }

    private var settingsFooter: some View {
        CompanionPanelSettingsFooter(appLanguage: appLanguage)
    }

    private func wizardHeader(title: String, onBack: @escaping () -> Void) -> some View {
        CompanionPanelWizardHeader(
            title: title,
            appLanguage: appLanguage,
            onBack: onBack,
            onOpenSettings: onOpenSettings,
            onQuit: onQuit
        )
    }

    private func copy(_ key: String) -> String {
        SpiderPanelCopy.text(key, language: appLanguage)
    }
}

struct CompanionPanelSettingsGeneralView: View {
    let appLanguage: SpiderAppLanguage
    @Binding var appLanguageRawValue: String
    @Binding var missionDraft: CompanionPanelMissionDraft
    let onBack: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            wizardHeader(title: copy("General"), onBack: onBack)

            VStack(spacing: 0) {
                CompanionPanelMenuRow(title: copy("Level"), value: missionDraft.experienceLevel, options: experienceLevelOptions) { selection in
                    missionDraft.experienceLevel = selection
                }
                CompanionPanelSurface.assetDivider
                CompanionPanelMenuRow(title: copy("Language"), value: generalLanguageValue, options: appLanguageOptions) { selection in
                    appLanguageRawValue = selection
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .background(CompanionPanelSurface.assetCard)

            settingsFooter
        }
    }

    private var experienceLevelOptions: [String] {
        CompanionPanelMissionOptions.experienceLevelOptions
    }

    private var appLanguageOptions: [String] {
        SpiderAppLanguage.allCases.map(\.rawValue)
    }

    private var generalLanguageValue: String {
        appLanguage.rawValue
    }

    private var settingsFooter: some View {
        CompanionPanelSettingsFooter(appLanguage: appLanguage)
    }

    private func wizardHeader(title: String, onBack: @escaping () -> Void) -> some View {
        CompanionPanelWizardHeader(
            title: title,
            appLanguage: appLanguage,
            onBack: onBack,
            onOpenSettings: onOpenSettings,
            onQuit: onQuit
        )
    }

    private func copy(_ key: String) -> String {
        SpiderPanelCopy.text(key, language: appLanguage)
    }
}

struct CompanionPanelSettingsPermissionsView: View {
    @ObservedObject var companionManager: CompanionManager
    let appLanguage: SpiderAppLanguage
    let onBack: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            wizardHeader(title: copy("Permissions"), onBack: onBack)

            VStack(spacing: 0) {
                CompanionPanelPermissionStatusRow(
                    title: copy("Voice mode"),
                    isOn: companionManager.hasMicrophonePermission,
                    action: requestMicrophonePermission
                )
                CompanionPanelSurface.assetDivider
                CompanionPanelPermissionStatusRow(
                    title: copy("Pointer overlay"),
                    isOn: companionManager.isSpiderCursorEnabled
                ) {
                    companionManager.setSpiderCursorEnabled(!companionManager.isSpiderCursorEnabled)
                }
                CompanionPanelSurface.assetDivider
                CompanionPanelPermissionStatusRow(
                    title: copy("Screen guidance"),
                    isOn: companionManager.hasScreenRecordingPermission && companionManager.hasScreenContentPermission
                ) {
                    if companionManager.hasScreenRecordingPermission {
                        companionManager.requestScreenContentPermission()
                    } else {
                        WindowPositionManager.requestScreenRecordingPermission()
                    }
                }
                CompanionPanelSurface.assetDivider
                CompanionPanelSettingsNavigationRow(title: copy("Ignored apps")) {
                    WindowPositionManager.openAccessibilitySettings()
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .background(CompanionPanelSurface.assetCard)

            settingsFooter
        }
    }

    private var settingsFooter: some View {
        CompanionPanelSettingsFooter(appLanguage: appLanguage)
    }

    private func wizardHeader(title: String, onBack: @escaping () -> Void) -> some View {
        CompanionPanelWizardHeader(
            title: title,
            appLanguage: appLanguage,
            onBack: onBack,
            onOpenSettings: onOpenSettings,
            onQuit: onQuit
        )
    }

    private func requestMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func copy(_ key: String) -> String {
        SpiderPanelCopy.text(key, language: appLanguage)
    }
}
