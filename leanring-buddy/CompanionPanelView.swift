//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the companion
//  voice status, push-to-talk shortcut, and quick settings. Designed to feel
//  like Loom's recording panel — dark, rounded, minimal, and special.
//

import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    private enum PanelTab {
        case main
        case settings
    }

    @ObservedObject var companionManager: CompanionManager
    @State private var emailInput: String = ""
    @State private var selectedTab: PanelTab = .main
    @State private var openRouterAPIKeyInput: String = ""
    @State private var elevenLabsAPIKeyInput: String = ""
    @State private var elevenLabsVoiceIDInput: String = ""
    @State private var settingsErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            tabSwitcherRow
                .padding(.top, 12)
                .padding(.horizontal, 16)

            if selectedTab == .main {
                mainTabContent
            } else {
                settingsTabContent
            }

            Spacer()
                .frame(height: 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(panelBackground)
        .onAppear {
            openRouterAPIKeyInput = companionManager.aiServiceSettings.openRouterAPIKey
            elevenLabsAPIKeyInput = companionManager.aiServiceSettings.elevenLabsAPIKey
            elevenLabsVoiceIDInput = companionManager.aiServiceSettings.elevenLabsVoiceID
            if companionManager.availableOpenRouterModels.isEmpty && companionManager.aiServiceSettings.hasOpenRouterAPIKey {
                companionManager.refreshOpenRouterModels()
            }
        }
    }

    private var tabSwitcherRow: some View {
        HStack(spacing: 8) {
            tabButton(title: "Main", isSelected: selectedTab == .main) {
                selectedTab = .main
            }
            tabButton(title: "Settings", isSelected: selectedTab == .settings) {
                selectedTab = .settings
            }
            Spacer()
        }
    }

    private func tabButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    @ViewBuilder
    private var mainTabContent: some View {
        permissionsCopySection
            .padding(.top, 16)
            .padding(.horizontal, 16)

        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Spacer().frame(height: 12)
            modelPickerRow
                .padding(.horizontal, 16)
        }

        if !companionManager.allPermissionsGranted {
            Spacer().frame(height: 16)
            settingsSection
                .padding(.horizontal, 16)
        }

        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Spacer().frame(height: 16)
            startButton
                .padding(.horizontal, 16)
        }

        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Spacer().frame(height: 12)
            clearContextButton
                .padding(.horizontal, 16)

        }

        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Spacer().frame(height: 16)
            dmFarzaButton
                .padding(.horizontal, 16)
        }
    }

    private var settingsTabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LOCAL SETTINGS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.top, 14)

            settingInputRow(title: "OpenRouter API Key", text: $openRouterAPIKeyInput, isSensitive: true)
            settingInputRow(title: "ElevenLabs API Key", text: $elevenLabsAPIKeyInput, isSensitive: true)
            settingInputRow(title: "ElevenLabs Voice ID", text: $elevenLabsVoiceIDInput, isSensitive: false)

            Button(action: saveServiceSettings) {
                Text("Save Keys")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.accent)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Multi-Turn", isOn: Binding(
                    get: { companionManager.isMultiTurnEnabled },
                    set: { companionManager.setMultiTurnEnabled($0) }
                ))
                .toggleStyle(.switch)
                .tint(DS.Colors.accent)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

                Text("When enabled, Clicky can continue an autonomous multi-turn loop from one request so it can handle longer tasks with follow-up replies, actions, and point events.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Defer voice until loop completes", isOn: Binding(
                    get: { companionManager.deferVoiceUntilAgenticLoopCompletes },
                    set: { companionManager.setDeferVoiceUntilAgenticLoopCompletes($0) }
                ))
                .toggleStyle(.switch)
                .tint(DS.Colors.accent)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .disabled(!companionManager.isMultiTurnEnabled)
                .opacity(companionManager.isMultiTurnEnabled ? 1.0 : 0.45)

                Text("When Multi-Turn is on, wait until the autonomous loop finishes before speaking the reply aloud — no voice after each intermediate step.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Computer Use", isOn: Binding(
                    get: { companionManager.isComputerUseEnabled },
                    set: { companionManager.setComputerUseEnabled($0) }
                ))
                .toggleStyle(.switch)
                .tint(DS.Colors.accent)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

                Text("When enabled, Clicky uses AppleScript (System Events) for most clicks and for typing. Coordinate clicks go to the frontmost app under the pointer; macOS may list each target app (Safari, Opera, Chrome, etc.) under Automation—allow Clicky for every app you want to control.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                if companionManager.isComputerUseEnabled {
                    computerUsePermissionRows
                    if !companionManager.hasAutomationPermission {
                        Text("Clicks and typing need Automation for System Events: use Grant next to Automation above, or System Settings → Privacy & Security → Automation. If a browser or editor does not respond, check that same Automation list for that app and enable Clicky.")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("If no consent dialog appears: quit and reopen Clicky, open this panel so the app is in the foreground, then tap Grant again. For local builds, set Xcode Signing & Capabilities → Team to your Apple ID (Personal Team is fine and does not require a paid membership); unsigned ad-hoc runs often fail Automation. If still stuck: Terminal — tccutil reset AppleEvents com.yourcompany.leanring-buddy — then Product → Clean Build Folder in Xcode, run again, and try Grant.")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(companionManager.computerUseRuntimeStatusMessage)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            HStack {
                Text("OpenRouter Model")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Button(action: {
                    companionManager.refreshOpenRouterModels()
                }) {
                    Text(companionManager.isLoadingOpenRouterModels ? "Loading..." : "Refresh")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(companionManager.isLoadingOpenRouterModels)
            }

            Toggle("Web-enabled only", isOn: Binding(
                get: { companionManager.showOnlyWebEnabledModels },
                set: { companionManager.setShowOnlyWebEnabledModels($0) }
            ))
            .toggleStyle(.switch)
            .tint(DS.Colors.accent)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(DS.Colors.textSecondary)

            Picker("OpenRouter Model", selection: Binding(
                get: { companionManager.selectedModel },
                set: { companionManager.setSelectedModel($0) }
            )) {
                ForEach(companionManager.visibleOpenRouterModels, id: \.id) { model in
                    Text(modelDisplayLabel(for: model))
                        .tag(model.id)
                }
            }
            .pickerStyle(.menu)
            .disabled(companionManager.visibleOpenRouterModels.isEmpty)

            Text("Used for each vision step: screenshots, spoken reply, actions, and pointing. Pick a cheaper model here if you use a separate orchestrator below.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Orchestrator model", selection: Binding(
                get: { companionManager.orchestratorOpenRouterModelID },
                set: { companionManager.setOrchestratorOpenRouterModelID($0) }
            )) {
                ForEach(companionManager.visibleOpenRouterModels, id: \.id) { model in
                    Text(modelDisplayLabel(for: model))
                        .tag(model.id)
                }
            }
            .pickerStyle(.menu)
            .disabled(companionManager.visibleOpenRouterModels.isEmpty)

            Text("Used only for Multi-Turn continuation turns (loop orchestration and [LOOP_CONTROL]). Use a stronger model here and a cheaper OpenRouter model above for step execution, or set both to the same model.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if companionManager.showOnlyWebEnabledModels
                && !companionManager.selectedModel.isEmpty
                && !companionManager.visibleOpenRouterModels.contains(where: { $0.id == companionManager.selectedModel }) {
                Text("Current selection is not web-enabled; choose a visible model to force native browsing.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            if companionManager.showOnlyWebEnabledModels
                && !companionManager.orchestratorOpenRouterModelID.isEmpty
                && !companionManager.visibleOpenRouterModels.contains(where: { $0.id == companionManager.orchestratorOpenRouterModelID }) {
                Text("Orchestrator model is not web-enabled; choose a visible model or turn off Web-enabled only.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            if let settingsErrorMessage, !settingsErrorMessage.isEmpty {
                Text(settingsErrorMessage)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.warning)
            } else if let modelError = companionManager.openRouterModelsErrorMessage, !modelError.isEmpty {
                Text(modelError)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.warning)
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var computerUsePermissionRows: some View {
        computerUsePermissionStatusRow(
            label: "Accessibility",
            isGranted: companionManager.hasAccessibilityPermission,
            grantAction: {
                _ = WindowPositionManager.requestAccessibilityPermission()
                companionManager.refreshAllPermissions(forceImmediateAutomationPermissionRecheck: true)
            }
        )

        computerUsePermissionStatusRow(
            label: "Automation",
            isGranted: companionManager.hasAutomationPermission,
            grantAction: {
                _ = companionManager.requestAutomationPermissionForComputerUse()
                companionManager.refreshAllPermissions(forceImmediateAutomationPermissionRecheck: true)
            }
        )

        if !companionManager.areComputerUsePermissionsGranted {
            Text("Grant Accessibility and Automation to enable computer control.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.warning)
        }
    }

    private func computerUsePermissionStatusRow(
        label: String,
        isGranted: Bool,
        grantAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: grantAction) {
                    Text("Grant")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    private func settingInputRow(title: String, text: Binding<String>, isSensitive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            Group {
                if isSensitive {
                    SecureField("", text: text)
                } else {
                    TextField("", text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
    }

    private func saveServiceSettings() {
        if let errorMessage = companionManager.saveOpenRouterAPIKey(openRouterAPIKeyInput) {
            settingsErrorMessage = errorMessage
            return
        }
        if let errorMessage = companionManager.saveElevenLabsAPIKey(elevenLabsAPIKeyInput) {
            settingsErrorMessage = errorMessage
            return
        }
        companionManager.saveElevenLabsVoiceID(elevenLabsVoiceIDInput)
        settingsErrorMessage = nil
        companionManager.refreshOpenRouterModels()
    }

    private func modelDisplayLabel(for model: OpenRouterModel) -> String {
        guard let modelName = model.name, !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return model.id
        }
        return "\(modelName) (\(model.id))"
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            HStack(spacing: 8) {
                // Animated status dot
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 4)

                Text("Clicky")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: {
                NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Permissions Copy

    @ViewBuilder
    private var permissionsCopySection: some View {
        if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            Text("Hold Control+Option to talk.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted && !companionManager.hasSubmittedEmail {
            VStack(alignment: .leading, spacing: 4) {
                Text("Drop your email to get started.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("If I keep building this, I'll keep you in the loop.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet Clicky.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // Permissions were revoked after onboarding — tell user to re-grant
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Some permissions were revoked. Grant all four below to keep using Clicky.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hi, I'm Farza. This is Clicky.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("A side project I made for fun to help me learn stuff as I use my computer.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Nothing runs in the background. Clicky will only take a screenshot when you press the hot key. So, you can give that permission in peace. If you are still sus, eh, I can't do much there champ.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.9, green: 0.4, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Email + Start Button

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            if !companionManager.hasSubmittedEmail {
                VStack(spacing: 8) {
                    TextField("Enter your email", text: $emailInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                        )

                    Button(action: {
                        companionManager.submitEmail(emailInput)
                    }) {
                        Text("Submit")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                    .fill(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                          ? DS.Colors.accent.opacity(0.4)
                                          : DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Button(action: {
                    companionManager.triggerOnboarding()
                }) {
                    Text("Start")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    // MARK: - Permissions

    private var settingsSection: some View {
        VStack(spacing: 2) {
            Text("PERMISSIONS")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 6)

            microphonePermissionRow

            accessibilityPermissionRow

            screenRecordingPermissionRow

            if companionManager.hasScreenRecordingPermission {
                screenContentPermissionRow
            }

        }
    }

    private var accessibilityPermissionRow: some View {
        let isGranted = companionManager.hasAccessibilityPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Accessibility")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                HStack(spacing: 6) {
                    Button(action: {
                        // Triggers the system accessibility prompt (AXIsProcessTrustedWithOptions)
                        // on first attempt, then opens System Settings on subsequent attempts.
                        WindowPositionManager.requestAccessibilityPermission()
                    }) {
                        Text("Grant")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(DS.Colors.accent)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: {
                        // Reveals the app in Finder so the user can drag it into
                        // the Accessibility list if it doesn't appear automatically
                        // (common with unsigned dev builds).
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("Find App")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        let isGranted = companionManager.hasScreenRecordingPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Recording")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(isGranted
                         ? "Only takes a screenshot when you use the hotkey"
                         : "Quit and reopen after granting")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS screen recording prompt on first
                    // attempt (auto-adds app to the list), then opens System Settings
                    // on subsequent attempts.
                    WindowPositionManager.requestScreenRecordingPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var screenContentPermissionRow: some View {
        let isGranted = companionManager.hasScreenContentPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Screen Content")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    companionManager.requestScreenContentPermission()
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private var microphonePermissionRow: some View {
        let isGranted = companionManager.hasMicrophonePermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text("Microphone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    // Triggers the native macOS microphone permission dialog on
                    // first attempt. If already denied, opens System Settings.
                    let status = AVCaptureDevice.authorizationStatus(for: .audio)
                    if status == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }

    private func permissionRow(
        label: String,
        iconName: String,
        isGranted: Bool,
        settingsURL: String
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            if isGranted {
                HStack(spacing: 4) {
                    Circle()
                        .fill(DS.Colors.success)
                        .frame(width: 6, height: 6)
                    Text("Granted")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.success)
                }
            } else {
                Button(action: {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Grant")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
    }



    // MARK: - Show Clicky Cursor Toggle

    private var showClickyCursorToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Show Clicky")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isClickyCursorEnabled },
                set: { companionManager.setClickyCursorEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
        }
        .padding(.vertical, 4)
    }

    private var speechToTextProviderRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "mic.badge.waveform")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Speech to Text")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Text(companionManager.buddyDictationManager.transcriptionProviderDisplayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Model Picker

    private var modelPickerRow: some View {
        HStack {
            Text("OpenRouter Model")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            Text(companionManager.selectedModel)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }

    // MARK: - DM Farza Button

    private var clearContextButton: some View {
        Button(action: {
            companionManager.clearConversationContext()
        }) {
            HStack(spacing: 8) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                Text("Clear Context")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(companionManager.hasConversationHistory ? DS.Colors.warning : DS.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(!companionManager.hasConversationHistory)
        .opacity(companionManager.hasConversationHistory ? 1.0 : 0.6)
    }

    private var dmFarzaButton: some View {
        Button(action: {
            if let url = URL(string: "https://x.com/farzatv") {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 12, weight: .medium))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Got feedback? DM me")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Bugs, ideas, anything — I read every message.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .foregroundColor(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button(action: {
                NSApp.terminate(nil)
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .medium))
                    Text("Quit Clicky")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if companionManager.hasCompletedOnboarding {
                Spacer()

                Button(action: {
                    companionManager.replayOnboarding()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.circle")
                            .font(.system(size: 11, weight: .medium))
                        Text("Watch Onboarding Again")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.blue400
        case .processing, .responding:
            return DS.Colors.blue400
        }
    }

    private var statusText: String {
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            return "Setup"
        }
        if !companionManager.isOverlayVisible {
            return "Ready"
        }
        switch companionManager.voiceState {
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

}
