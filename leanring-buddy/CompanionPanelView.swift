//
//  CompanionPanelView.swift
//  leanring-buddy
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the companion
//  voice status, push-to-talk shortcut, and quick settings. Designed to feel
//  like Loom's recording panel — dark, rounded, minimal, and special.
//

import AVFoundation
import AppKit
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var accountManager: DotAccountManager
    @ObservedObject var remoteCommandSubscriber: RemoteCommandSubscriber

    @AppStorage(RemoteCommandSubscriber.remoteControlEnabledUserDefaultsKey)
    private var isRemoteControlEnabled: Bool = false

    var body: some View {
        if accountManager.isSignedIn {
            signedInBody
        } else {
            signedOutBody
        }
    }

    private var serverSafetyModeMessages: [String] {
        let flags = accountManager.clientFeatureFlags
        var messages: [String] = []
        if !flags.agentToolsEnabled {
            messages.append("Computer-control tools are off. Dot can still answer without clicking or typing.")
        }
        if !flags.backgroundAgentsEnabled {
            messages.append("Background coding agents are off.")
        }
        if !flags.memoryEnabled {
            messages.append("Long-term memory is off.")
        }
        if !flags.ttsEnabled {
            messages.append("ElevenLabs voice is off; Dot will use the Mac system voice.")
        }
        return messages
    }

    private var serverSafetyModeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.warning)
                Text("Server safe mode")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                ForEach(serverSafetyModeMessages, id: \.self) { message in
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.warning.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.warning.opacity(0.16), lineWidth: 1)
        )
    }

    // MARK: - Remote control toggle + audit row
    //
    // Off by default. Flipping on opens a WebSocket to vibe-id and starts
    // accepting `dot.command.issued` events from the user's phone or any
    // other signed-in surface. The audit row lists the last ~5 events
    // delivered to THIS Mac with completion status, so the user can see
    // at a glance what remote has been issuing.

    @ViewBuilder
    fileprivate var remoteControlSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(isOn: $isRemoteControlEnabled) {
                    Text("remote control")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .onChange(of: isRemoteControlEnabled) { newValue in
                    remoteCommandSubscriber.setRemoteControlEnabled(newValue)
                }
                Spacer()
                if isRemoteControlEnabled {
                    Circle()
                        .fill(remoteCommandSubscriber.isWebSocketConnected ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                        .help(
                            remoteCommandSubscriber.isWebSocketConnected
                                ? "connected"
                                : (remoteCommandSubscriber.lastErrorDescription ?? "connecting…")
                        )
                }
            }

            if isRemoteControlEnabled {
                Text("phone commands signed into the same Google account land here.")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
            }

            if remoteCommandSubscriber.coldBootReplayBannerEventCount > 0 {
                HStack(spacing: 6) {
                    Text(
                        "\(remoteCommandSubscriber.coldBootReplayBannerEventCount) older command\(remoteCommandSubscriber.coldBootReplayBannerEventCount == 1 ? "" : "s") replayed after wake"
                    )
                    .font(.system(size: 10))
                    .foregroundColor(.yellow.opacity(0.9))
                    Spacer()
                    Button("dismiss") {
                        remoteCommandSubscriber.dismissColdBootReplayBanner()
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.plain)
                    .foregroundColor(.white.opacity(0.6))
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background(Color.yellow.opacity(0.08))
                .cornerRadius(4)
            }

            if isRemoteControlEnabled, !remoteCommandSubscriber.recentDeliveredEvents.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(remoteCommandSubscriber.recentDeliveredEvents.prefix(5)) { event in
                        HStack(spacing: 6) {
                            Text(event.payload["transcript"] ?? event.eventType)
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.7))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Text(event.completedStatus ?? "running…")
                                .font(.system(size: 10))
                                .foregroundColor(remoteCommandStatusColor(for: event.completedStatus))
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func remoteCommandStatusColor(for status: String?) -> Color {
        switch status {
        case "completed": return .green.opacity(0.8)
        case "cancelled": return .white.opacity(0.45)
        case "failed":    return .red.opacity(0.8)
        default:          return .white.opacity(0.45)
        }
    }

    // MARK: - Signed-in body (existing flow)

    private var signedInBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            permissionsCopySection
                .padding(.top, 16)
                .padding(.horizontal, 16)

            if !serverSafetyModeMessages.isEmpty {
                Spacer()
                    .frame(height: 10)

                serverSafetyModeSection
                    .padding(.horizontal, 16)
            }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 12)

                modelPickerRow
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 10)

                voiceVolumeRow
                    .padding(.horizontal, 16)
            }

            if !companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                settingsSection
                    .padding(.horizontal, 16)
            }

            if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                Spacer()
                    .frame(height: 16)

                startButton
                    .padding(.horizontal, 16)
            }

            // Show Dot toggle — hidden for now
            // if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
            //     Spacer()
            //         .frame(height: 16)
            //
            //     showDotCursorToggleRow
            //         .padding(.horizontal, 16)
            // }

            if companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
                if !companionManager.recentMemoryWriteToastEntries.isEmpty {
                    Spacer()
                        .frame(height: 12)

                    memoryWriteToastList
                        .padding(.horizontal, 16)
                }

                Spacer()
                    .frame(height: 12)

                MemoryInspectorView(companionManager: companionManager)
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 16)

                remoteControlSection
                    .padding(.horizontal, 16)

                Spacer()
                    .frame(height: 12)

                feedbackButton
                    .padding(.horizontal, 16)
            }

            Spacer()
                .frame(height: 12)

            signedInAccountRow
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            footerSection
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(panelBackground)
    }

    // MARK: - Signed-out body (sign-in gate)

    private var signedOutBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 14) {
                Text("Sign in to use Dot")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text("Dot uses your Vibe Research credits for Claude, ElevenLabs, and AssemblyAI. Sign in to see your balance, refill usage, and keep abuse off the shared server.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: {
                    accountManager.signIn()
                }) {
                    HStack(spacing: 8) {
                        if accountManager.isSigningIn {
                            ProgressView()
                                .scaleEffect(0.6)
                                .progressViewStyle(.circular)
                        } else {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .font(.system(size: 13, weight: .medium))
                        }
                        Text(accountManager.isSigningIn ? "Waiting for browser…" : "Sign in with Google")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .fill(DS.Colors.blue400)
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(accountManager.isSigningIn)

                if let errorMessage = accountManager.lastErrorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.destructiveText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 16)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            HStack {
                Button(action: { NSApp.terminate(nil) }) {
                    HStack(spacing: 6) {
                        Image(systemName: "power")
                            .font(.system(size: 11, weight: .medium))
                        Text("Quit Dot")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 320)
        .background(panelBackground)
    }

    // MARK: - Signed-in account row (above footer)

    private var signedInAccountRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.success)

            VStack(alignment: .leading, spacing: 1) {
                Text(accountManager.userEmail ?? "Signed in")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let creditsBalance = accountManager.creditsBalance {
                    // Credits are stored as cents; display as dollars.
                    let dollarsString = String(format: "%.2f", Double(creditsBalance) / 100.0)
                    HStack(spacing: 6) {
                        Text("$\(dollarsString) balance")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)

                        Button(action: openAccountRefillPage) {
                            Text("Add credits")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(DS.Colors.blue400)
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                }
            }

            Spacer()

            Button(action: {
                accountManager.signOut()
            }) {
                Text("Sign out")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    private func openAccountRefillPage() {
        guard let accountURL = URL(string: VibeIdInsufficientCreditsError.refillAccountURLString) else {
            return
        }
        NSWorkspace.shared.open(accountURL)
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

                Text("Dot")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: {
                NotificationCenter.default.post(name: .dotDismissPanel, object: nil)
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
            VStack(alignment: .leading, spacing: 5) {
                Text("Hold Control+Option to talk.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Each turn sends your transcript and a fresh screenshot through Vibe Research to Claude.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.allPermissionsGranted {
            Text("You're all set. Hit Start to meet Dot.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if companionManager.hasCompletedOnboarding {
            // Permissions were revoked after onboarding — tell user to re-grant
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions needed")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Some permissions were revoked. Grant the permissions below to keep using Dot.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Hi, I'm Mark. This is Dot.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("A side project I made for fun to help me learn stuff as I use my computer.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Dot does not continuously record your screen. When you press the hotkey, that turn sends your transcript and a fresh screenshot through Vibe Research to Claude.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Start Button

    @ViewBuilder
    private var startButton: some View {
        if !companionManager.hasCompletedOnboarding && companionManager.allPermissionsGranted {
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

            inputMonitoringPermissionRow

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
            }
        }
        .padding(.vertical, 6)
    }

    private var inputMonitoringPermissionRow: some View {
        let isGranted = companionManager.hasInputMonitoringPermission
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Input Monitoring")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text("Needed for Control+Option")
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
                    WindowPositionManager.requestInputMonitoringPermission()
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
        let isChecking = companionManager.isRequestingScreenContent
        // Once a probe or real capture has detected denial, we show recovery
        // controls (Open Settings + Relaunch) instead of the initial "Verify"
        // button — because re-running Verify on a denied app just pops the
        // system dialog again without making forward progress, and the actual
        // fix requires the user to flip the toggle in Settings then relaunch.
        let hasKnownPermissionProblem = companionManager.screenContentPermissionProblem != nil
        return HStack(alignment: .top) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "eye")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Screen Capture")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text(companionManager.screenContentPermissionProblem ?? "Verifies production capture access")
                        .font(.system(size: 10))
                        .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
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
            } else if hasKnownPermissionProblem {
                VStack(alignment: .trailing, spacing: 4) {
                    Button(action: {
                        companionManager.openScreenRecordingSystemSettings()
                    }) {
                        Text("Open Settings")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(DS.Colors.accent))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    Button(action: {
                        companionManager.relaunchAppAfterPermissionChange()
                    }) {
                        Text("Relaunch")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textOnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(DS.Colors.accent))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            } else {
                Button(action: {
                    companionManager.requestScreenContentPermission()
                }) {
                    Text(isChecking ? "Checking" : "Verify")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(DS.Colors.accent)
                        )
                }
                .disabled(isChecking)
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



    // MARK: - Show Dot Cursor Toggle

    private var showDotCursorToggleRow: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 16)

                Text("Show Dot")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { companionManager.isDotCursorEnabled },
                set: { companionManager.setDotCursorEnabled($0) }
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

    private var voiceVolumeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: companionManager.isSpeechMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(companionManager.isSpeechMuted ? DS.Colors.textTertiary : DS.Colors.blue400)
                .frame(width: 16)
                .help(companionManager.isSpeechMuted ? "Voice muted. TTS requests are skipped." : "Voice volume")

            Text("Voice")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Slider(
                value: Binding(
                    get: { companionManager.speechVolume },
                    set: { companionManager.setSpeechVolume($0) }
                ),
                in: 0...1
            )
            .controlSize(.small)
            .tint(DS.Colors.blue400)

            Text(companionManager.isSpeechMuted ? "off" : "\(Int((companionManager.speechVolume * 100).rounded()))%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Feedback Button

    /// Phase 3b trust surface: stack of recent memory writes the model
    /// silently performed. Each row shows what was saved + Undo / dismiss
    /// affordances so prompt-injection or model-confabulation can be
    /// caught before it persists. Empty state hidden by the caller.
    private var memoryWriteToastList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(companionManager.recentMemoryWriteToastEntries) { toastEntry in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: toastEntry.supportsUndo ? "brain.head.profile" : "sparkles")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                    Text(toastEntry.displayMessage)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if toastEntry.supportsUndo {
                        Button(action: {
                            companionManager.undoMemoryWriteToast(toastID: toastEntry.id)
                        }) {
                            Text("Undo")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                    Button(action: {
                        companionManager.dismissMemoryWriteToast(toastID: toastEntry.id)
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
            }
        }
    }

    private var feedbackButton: some View {
        Button(action: {
            if let url = URL(string: "https://x.com/clamepending") {
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
                    Text("Quit Dot")
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
            } else {
                Spacer()
            }

            if let availableUpdateVersion = companionManager.availableUpdateVersion {
                Button(action: {
                    companionManager.requestInstallAvailableUpdate()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Update to v\(availableUpdateVersion)")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(DS.Colors.textOnAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(DS.Colors.accent))
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .padding(.leading, 8)
            }

            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(DS.Colors.textTertiary.opacity(0.5))
                .padding(.leading, 8)
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
        if !serverSafetyModeMessages.isEmpty {
            return "Safe mode"
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
