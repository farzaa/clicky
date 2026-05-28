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

private enum CompanionPanelTab: String, CaseIterable, Identifiable {
    case home
    case brain
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .brain: return "Brain"
        case .settings: return "Settings"
        }
    }
}

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var emailInput: String = ""
    @State private var isShowingTeachingSkillsLibrary = false
    @State private var showsNicheOverridePicker = false
    @State private var showsSuggestedAsks = false
    @State private var isShowingVaultConnectionSheet = false
    @State private var discoveredVaults: [DiscoveredVault] = []
    @State private var copiedSuggestionText: String?
    @State private var selectedPanelTab: CompanionPanelTab = CompanionPanelView.loadSelectedPanelTab()

    private static let selectedPanelTabUserDefaultsKey = "panelSelectedTab"

    var body: some View {
        if isShowingVaultConnectionSheet {
            vaultConnectionContent
        } else if isShowingTeachingSkillsLibrary {
            TeachingSkillsLibraryView(companionManager: companionManager) {
                isShowingTeachingSkillsLibrary = false
            }
            .frame(width: 320)
            .background(panelBackground)
        } else {
            mainPanelContent
        }
    }

    private var vaultConnectionContent: some View {
        VaultConnectionSheet(
            discoveredVaults: discoveredVaults,
            onConnectDiscoveredVault: { discoveredVault in
                let didConnectVault = companionManager.connectDiscoveredVault(discoveredVault)
                if didConnectVault {
                    isShowingVaultConnectionSheet = false
                }
            },
            onChooseDifferentFolder: {
                isShowingVaultConnectionSheet = false
                companionManager.chooseVaultFolderManually()
            },
            onCancel: {
                isShowingVaultConnectionSheet = false
            }
        )
        .frame(width: 320)
        .background(panelBackground)
    }

    private var mainPanelContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            if showsPanelTabs {
                panelTabBar

                Divider()
                    .background(DS.Colors.borderSubtle)
                    .padding(.horizontal, 16)

                selectedTabContent
                    .padding(.horizontal, 16)
            } else {
                setupPanelBody
                    .padding(.horizontal, 16)
            }

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 18)
        }
        .frame(width: 320)
        .background(panelBackground)
        .onChange(of: companionManager.pendingVaultWrite?.id) { _, pendingVaultWriteID in
            guard pendingVaultWriteID != nil else { return }
            selectPanelTab(.brain)
        }
        .onChange(of: selectedPanelTab) { _, _ in
            persistSelectedPanelTab()
            notifyPanelLayoutDidChange()
        }
        .onChange(of: showsSuggestedAsks) { _, _ in
            notifyPanelLayoutDidChange()
        }
    }

    private var showsPanelTabs: Bool {
        companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted
    }

    private var selectedTabContent: some View {
        Group {
            switch selectedPanelTab {
            case .home:
                homeTabContent
            case .brain:
                brainTabContent
            case .settings:
                settingsTabContent
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 20)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            notifyPanelLayoutDidChange()
        }
    }

    private var setupPanelBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            permissionsCopySection
                .padding(.top, 16)

            if !companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                settingsSection
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                startButton
            }
        }
        .padding(.bottom, 20)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            notifyPanelLayoutDidChange()
        }
    }

    // MARK: - Tab Bar

    private var panelTabBar: some View {
        HStack(spacing: 4) {
            ForEach(CompanionPanelTab.allCases) { panelTab in
                panelTabButton(panelTab)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func panelTabButton(_ panelTab: CompanionPanelTab) -> some View {
        let isSelected = selectedPanelTab == panelTab

        return Button {
            selectPanelTab(panelTab)
        } label: {
            HStack(spacing: 5) {
                Text(panelTab.title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))

                if panelTab == .brain && companionManager.pendingVaultWrite != nil {
                    Circle()
                        .fill(DS.Colors.accent)
                        .frame(width: 6, height: 6)
                }
            }
            .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(isSelected ? DS.Colors.borderSubtle : Color.clear, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityIdentifier("clicky.panel.tab.\(panelTab.rawValue)")
    }

    // MARK: - Home Tab

    private var homeTabContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            permissionsCopySection

            if let pendingVaultWrite = companionManager.pendingVaultWrite {
                pendingVaultWriteHomeBanner(pendingVaultWrite)
            }

            if showsSuggestedAsksSection {
                nicheSuggestionsSection
            }
        }
    }

    private func pendingVaultWriteHomeBanner(_ pendingVaultWrite: PendingVaultWrite) -> some View {
        Button(action: {
            selectPanelTab(.brain)
        }) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "doc.badge.clock")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(DS.Colors.accent)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Vault save pending")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(pendingVaultWrite.targetDescription)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text("Open Brain tab to confirm")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.accent)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(DS.Colors.surface2)
            .cornerRadius(DS.CornerRadius.medium)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityIdentifier("clicky.panel.home.pending-vault-write")
    }

    // MARK: - Brain Tab

    private var brainTabContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                brainTabSectionHeader(
                    title: "Personal Vault",
                    trailingContent: {
                        if companionManager.connectedVaultSummaries.isEmpty {
                            Button("Connect vault") {
                                discoveredVaults = companionManager.discoverObsidianVaults()
                                isShowingVaultConnectionSheet = true
                            }
                            .buttonStyle(DSTextButtonStyle())
                            .accessibilityIdentifier("clicky.panel.vault.connect")
                        }
                    }
                )

                personalVaultSectionContent
            }

            VStack(alignment: .leading, spacing: 8) {
                brainTabSectionHeader(title: "Teaching Skills")
                teachingSkillsSectionContent
            }
        }
    }

    private func brainTabSectionHeader<TrailingContent: View>(
        title: String,
        @ViewBuilder trailingContent: () -> TrailingContent = { EmptyView() }
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer(minLength: 0)

            trailingContent()
        }
    }

    // MARK: - Settings Tab

    private var settingsTabContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            modelPickerRow
            showClickyCursorToggleRow
            speechToTextProviderRow

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

            dmFarzaButton
        }
    }

    private static func loadSelectedPanelTab() -> CompanionPanelTab {
        guard let savedTabRawValue = UserDefaults.standard.string(forKey: selectedPanelTabUserDefaultsKey),
              let savedPanelTab = CompanionPanelTab(rawValue: savedTabRawValue) else {
            return .home
        }

        return savedPanelTab
    }

    private func selectPanelTab(_ panelTab: CompanionPanelTab) {
        selectedPanelTab = panelTab
        persistSelectedPanelTab()
        notifyPanelLayoutDidChange()
    }

    private func persistSelectedPanelTab() {
        UserDefaults.standard.set(selectedPanelTab.rawValue, forKey: Self.selectedPanelTabUserDefaultsKey)
    }

    private func notifyPanelLayoutDidChange() {
        NotificationCenter.default.post(name: .clickyPanelLayoutDidChange, object: nil)
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
            HStack(alignment: .center, spacing: 8) {
                Text("Hold Control+Option to talk.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Spacer(minLength: 0)

                if companionManager.voiceState == .idle {
                    suggestedAsksToggleButton
                }
            }
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

    // MARK: - Niche Discovery

    private var showsSuggestedAsksSection: Bool {
        companionManager.hasCompletedOnboarding
            && companionManager.allPermissionsGranted
            && companionManager.voiceState == .idle
            && showsSuggestedAsks
    }

    private var suggestedAsksToggleButton: some View {
        Button(action: {
            showsSuggestedAsks.toggle()
            if !showsSuggestedAsks {
                showsNicheOverridePicker = false
            }
        }) {
            Image(systemName: showsSuggestedAsks ? "questionmark.circle.fill" : "questionmark.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(showsSuggestedAsks ? DS.Colors.accent : DS.Colors.textTertiary)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(showsSuggestedAsks ? DS.Colors.accent.opacity(0.15) : Color.white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .accessibilityLabel(showsSuggestedAsks ? "Hide suggested asks" : "Show suggested asks")
        .accessibilityIdentifier("clicky.panel.suggested-asks.toggle")
    }

    private var nicheSuggestionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(companionManager.nicheSuggestionContextLabel ?? "Try asking about your screen:")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(companionManager.nicheSuggestions) { suggestion in
                nicheSuggestionCard(suggestion)
            }
            .id(
                (companionManager.selectedUserNiche?.rawValue ?? "automatic")
                    + "-"
                    + (companionManager.nicheSuggestions.map(\.id).joined(separator: ","))
            )

            Button(action: {
                showsNicheOverridePicker.toggle()
            }) {
                Text(showsNicheOverridePicker ? "Hide suggestion tuning" : "Suggestions feel wrong?")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if showsNicheOverridePicker {
                nicheOverridePicker
            }
        }
        .padding(.vertical, 4)
    }

    private var nicheOverridePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pick a better fit:")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 72), spacing: 6)],
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(overrideNicheOptions) { niche in
                    nicheChipButton(niche)
                }
            }

            if companionManager.selectedUserNiche != nil {
                Button(action: {
                    companionManager.clearUserNicheOverride()
                }) {
                    Text("Use automatic suggestions again")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.accent)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    private var overrideNicheOptions: [NicheDiscoveryManager.Niche] {
        [.developer, .designer, .contentCreator, .other]
    }

    private func nicheChipButton(_ niche: NicheDiscoveryManager.Niche) -> some View {
        let isSelected = companionManager.selectedUserNiche == niche
        return Button(action: {
            companionManager.setUserNiche(niche)
        }) {
            Text(niche.displayName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.12) : Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isSelected ? DS.Colors.accent.opacity(0.5) : DS.Colors.borderSubtle, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private func nicheSuggestionCard(_ suggestion: NicheSuggestion) -> some View {
        Button(action: {
            companionManager.askWithSuggestion(suggestion)
        }) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.accent)
                    .padding(.top, 2)

                Text(suggestion.prompt)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
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


    // MARK: - Teaching Skills

    private var teachingSkillsSectionContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Learn from sessions")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Spacer()

                Toggle("", isOn: Binding(
                    get: { companionManager.isLearningFromSessionsEnabled },
                    set: { companionManager.setLearningFromSessionsEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.accent)
                .scaleEffect(0.8)
                .accessibilityIdentifier("clicky.panel.teaching-skills.learn-toggle")
            }

            Text(companionManager.isLearningFromSessionsEnabled
                 ? "Clicky learns from successful tutoring sessions."
                 : "Learning paused — saved skills still apply.")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)

            if companionManager.teachingSkills.isEmpty {
                Text("No skills yet. Teach Clicky something on screen and confirm it worked.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(companionManager.teachingSkills.prefix(4)) { skill in
                    teachingSkillRow(skill)
                }

                Button(action: {
                    isShowingTeachingSkillsLibrary = true
                }) {
                    Text("View all")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.accent)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityIdentifier("clicky.panel.teaching-skills.view-all")
            }
        }
    }

    private func teachingSkillRow(_ skill: TeachingSkill) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)

                Text("\(skill.usageCount) uses • \(skill.status.rawValue)")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Spacer()

            Button(action: {
                companionManager.setTeachingSkillPinned(id: skill.id, pinned: !skill.isPinned)
            }) {
                Image(systemName: skill.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(skill.isPinned ? DS.Colors.accent : DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button(action: {
                companionManager.deleteTeachingSkill(id: skill.id)
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Personal Vault

    private var personalVaultSectionContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if companionManager.connectedVaultSummaries.isEmpty {
                Text("Connect Obsidian or markdown notes. Clicky reads them only when you ask about your vault or internal knowledge.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                vaultWriteToggleRow

                if companionManager.isVaultWriteEnabled {
                    Text("Writes can save to ~/.clicky/brain/MEMORY.md even without a connected vault.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ForEach(companionManager.connectedVaultSummaries) { connectedVault in
                    connectedVaultRow(connectedVault)
                }

                vaultWriteToggleRow

                Text(vaultConnectionStatusText)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)

                if !companionManager.lastVaultNotesUsed.isEmpty {
                    Text("Last turn used \(companionManager.lastVaultNotesUsed.count) note\(companionManager.lastVaultNotesUsed.count == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.accentText)
                }

                Button("Add another vault") {
                    discoveredVaults = companionManager.discoverObsidianVaults()
                    isShowingVaultConnectionSheet = true
                }
                .buttonStyle(DSTextButtonStyle())
                .accessibilityIdentifier("clicky.panel.vault.add-another")
            }

            if let pendingVaultWrite = companionManager.pendingVaultWrite {
                pendingVaultWriteConfirmationCard(pendingVaultWrite)
            }

            if let lastVaultWriteStatusMessage = companionManager.lastVaultWriteStatusMessage {
                Text(lastVaultWriteStatusMessage)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let vaultConnectionErrorMessage = companionManager.vaultConnectionErrorMessage {
                Text(vaultConnectionErrorMessage)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func connectedVaultRow(_ connectedVault: ConnectedVault) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(connectedVault.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)

                Text(connectedVault.path)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button(action: {
                companionManager.disconnectVault(id: connectedVault.id)
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityIdentifier("clicky.panel.vault.disconnect.\(connectedVault.id.uuidString)")
        }
        .padding(.vertical, 4)
    }

    private var vaultConnectionStatusText: String {
        let writeAccessLabel = companionManager.isVaultWriteEnabled ? "writes enabled" : "read-only"
        return "Connected · \(companionManager.connectedVaultMarkdownFileCount) notes · \(writeAccessLabel)"
    }

    private var vaultWriteToggleRow: some View {
        HStack {
            Text("Allow vault writes")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isVaultWriteEnabled },
                set: { companionManager.setVaultWriteEnabled($0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(DS.Colors.accent)
            .scaleEffect(0.8)
            .accessibilityIdentifier("clicky.panel.vault.write-toggle")
        }
        .padding(.vertical, 2)
    }

    private func pendingVaultWriteConfirmationCard(_ pendingVaultWrite: PendingVaultWrite) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Confirm save")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)

            Text(pendingVaultWrite.targetDescription)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Text(pendingVaultWrite.previewBody)
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Save") {
                    companionManager.confirmPendingVaultWrite()
                }
                .buttonStyle(DSPrimaryButtonStyle())
                .accessibilityIdentifier("clicky.panel.vault.write.confirm")

                Button("Cancel") {
                    companionManager.cancelPendingVaultWrite()
                }
                .buttonStyle(DSTextButtonStyle())
                .accessibilityIdentifier("clicky.panel.vault.write.cancel")
            }
        }
        .padding(10)
        .background(DS.Colors.surface2)
        .cornerRadius(DS.CornerRadius.medium)
    }

    // MARK: - Model Picker

    private var modelPickerRow: some View {
        HStack {
            Text("Model")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Spacer()

            HStack(spacing: 0) {
                modelOptionButton(label: "Sonnet", modelID: "claude-sonnet-4-6")
                modelOptionButton(label: "Opus", modelID: "claude-opus-4-6")
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
        }
        .padding(.vertical, 4)
    }

    private func modelOptionButton(label: String, modelID: String) -> some View {
        let isSelected = companionManager.selectedModel == modelID
        return Button(action: {
            companionManager.setSelectedModel(modelID)
        }) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - DM Farza Button

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
