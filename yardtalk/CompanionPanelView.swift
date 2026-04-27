//
//  CompanionPanelView.swift
//  yardtalk
//
//  The SwiftUI content hosted inside the menu bar panel during the YardTalk
//  skeleton phase. Shows app status and the four permission rows. The Clicky
//  panel UI (model picker, push-to-talk hints, onboarding flow, cursor
//  toggle, "DM Farza" link) was stripped — session controls land here once
//  Pile C ships.
//

import AVFoundation
import SwiftUI

struct CompanionPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var screen: ProjectPickerScreen = .main

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            switch screen {
            case .main:
                mainContent
            case .newProject:
                NewProjectForm(
                    store: companionManager.projectStore,
                    screen: $screen
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            case .manage:
                ManageProjectsView(
                    store: companionManager.projectStore,
                    screen: $screen
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }

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

    @ViewBuilder
    private var mainContent: some View {
        statusCopy
            .padding(.top, 16)
            .padding(.horizontal, 16)

        if !companionManager.allPermissionsGranted {
            Spacer().frame(height: 16)
            permissionsSection
                .padding(.horizontal, 16)
        } else {
            Spacer().frame(height: 16)
            ProjectPickerRow(
                store: companionManager.projectStore,
                screen: $screen
            )
            .padding(.horizontal, 16)

            Spacer().frame(height: 16)
            sessionSection
                .padding(.horizontal, 16)
        }

        Spacer().frame(height: 12)
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: statusDotColor.opacity(0.6), radius: 4)

                Text("YardTalk")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
            }

            Spacer()

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)

            Button(action: {
                NotificationCenter.default.post(name: .dismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var statusDotColor: Color {
        companionManager.allPermissionsGranted ? DS.Colors.success : DS.Colors.warning
    }

    private var statusText: String {
        companionManager.allPermissionsGranted ? "Ready" : "Setup"
    }

    // MARK: - Status Copy

    @ViewBuilder
    private var statusCopy: some View {
        if companionManager.allPermissionsGranted {
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions all granted.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("Hold ⌃⌥ anywhere on your Mac to record a narrated screen clip. Release to stop and transcribe.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to YardTalk.")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("YardTalk records narrated screen clips during work sessions and synthesizes them into per-project reports. Grant the permissions below to get started.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Nothing runs in the background. YardTalk only captures when you start a session.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.9, green: 0.4, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
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

    private var microphonePermissionRow: some View {
        permissionRow(
            label: "Microphone",
            iconName: "mic",
            isGranted: companionManager.hasMicrophonePermission
        ) {
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // Two-button row: Grant + Find App. Accessibility is the only permission
    // with the unsigned-build "drag into list" workaround, so it doesn't share
    // the generic permissionRow helper.
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
                grantedBadge
            } else {
                HStack(spacing: 6) {
                    grantButton {
                        WindowPositionManager.requestAccessibilityPermission()
                    }
                    Button(action: {
                        WindowPositionManager.revealAppInFinder()
                        WindowPositionManager.openAccessibilitySettings()
                    }) {
                        Text("Find App")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Capsule().stroke(DS.Colors.borderSubtle, lineWidth: 0.8))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var screenRecordingPermissionRow: some View {
        permissionRow(
            label: "Screen Recording",
            iconName: "rectangle.dashed.badge.record",
            isGranted: companionManager.hasScreenRecordingPermission,
            sublabel: companionManager.hasScreenRecordingPermission
                ? "Required for narrated screen clips"
                : "Quit and reopen after granting"
        ) {
            WindowPositionManager.requestScreenRecordingPermission()
        }
    }

    private var screenContentPermissionRow: some View {
        permissionRow(
            label: "Screen Content",
            iconName: "eye",
            isGranted: companionManager.hasScreenContentPermission
        ) {
            companionManager.requestScreenContentPermission()
        }
    }

    // MARK: - Permission Row Helpers

    private func permissionRow(
        label: String,
        iconName: String,
        isGranted: Bool,
        sublabel: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isGranted ? DS.Colors.textTertiary : DS.Colors.warning)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    if let sublabel {
                        Text(sublabel)
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
            }
            Spacer()
            if isGranted {
                grantedBadge
            } else {
                grantButton(action: action)
            }
        }
        .padding(.vertical, 6)
    }

    private var grantedBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(DS.Colors.success)
                .frame(width: 6, height: 6)
            Text("Granted")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.success)
        }
    }

    private func grantButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Grant")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(DS.Colors.accent))
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Session

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sessionStatusRow
            clipsList
        }
    }

    @ViewBuilder
    private var sessionStatusRow: some View {
        switch companionManager.sessionManager.status {
        case .idle:
            HStack(spacing: 8) {
                Image(systemName: "circle")
                    .foregroundColor(DS.Colors.textTertiary)
                    .font(.system(size: 9, weight: .semibold))
                Text("Hold ⌃⌥ to record")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
            }
        case .recording:
            HStack(spacing: 8) {
                Image(systemName: "circle.fill")
                    .foregroundColor(.red)
                    .font(.system(size: 9))
                Text("Recording…")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                AudioLevelMeter(level: companionManager.sessionManager.audioLevel)
                    .frame(width: 80, height: 6)
            }
        case .finishing:
            HStack(spacing: 8) {
                Image(systemName: "circle.fill")
                    .foregroundColor(DS.Colors.warning)
                    .font(.system(size: 9))
                Text("Saving clip…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
            }
        case .failed(let message):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(DS.Colors.warning)
                    .font(.system(size: 11))
                    .padding(.top, 1)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var clipsList: some View {
        let clips = companionManager.clipStore.clipsForActiveProject
        if !clips.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("RECENT CLIPS")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.textTertiary)
                ForEach(clips.prefix(3)) { clip in
                    clipRow(clip)
                }
                if clips.count > 3 {
                    Text("+ \(clips.count - 3) older clip\(clips.count - 3 == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
        }
    }

    private func clipRow(_ clip: YardTalkClip) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(clip.recordedAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("\(Int(clip.durationSeconds.rounded()))s")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                Spacer()
            }
            clipTranscriptCopy(clip)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    @ViewBuilder
    private func clipTranscriptCopy(_ clip: YardTalkClip) -> some View {
        if let error = clip.transcriptionError {
            Text("Transcription failed: \(error)")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } else if let transcript = clip.transcript {
            if transcript.isEmpty {
                Text("(empty)")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            } else {
                Text(transcript)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        } else {
            Text("Transcribing…")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
        }
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
                    Text("Quit YardTalk")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Spacer()

            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    // MARK: - Visual Helpers

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(DS.Colors.background)
            .shadow(color: Color.black.opacity(0.5), radius: 20, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 2)
    }
}

/// Horizontal mic-level bar shown next to "Recording…". Color shifts toward
/// red near clipping so loud peaks are visible and a flat bar at zero is
/// unmistakable when the mic isn't actually capturing.
private struct AudioLevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(meterColor)
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, level))))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
    }

    private var meterColor: Color {
        if level > 0.9 { return Color(red: 0.95, green: 0.35, blue: 0.35) }
        if level > 0.7 { return Color(red: 0.95, green: 0.8, blue: 0.3) }
        return DS.Colors.success
    }
}
