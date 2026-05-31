//
//  CompanionPanelView.swift
//  yardtalk
//
//  The SwiftUI content hosted inside the menu bar panel. Shows the permission
//  rows during setup, then the active project, recording status (screen clip
//  or voice note), and the current session's timeline once permissions are
//  granted.
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
            case .timeline:
                TimelineView(
                    sessionStore: companionManager.sessionStore,
                    clipStore: companionManager.clipStore,
                    synthesisService: companionManager.synthesisService,
                    videoURL: { companionManager.clipStore.videoFileURL(for: $0) },
                    onSynthesize: { [companionManager] session in
                        companionManager.triggerSynthesis(for: session)
                    },
                    hasNUPAT: companionManager.hasNUPAT,
                    onUpload: { [companionManager] session in
                        await companionManager.uploadSession(session)
                    },
                    screen: $screen
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            case .editProject(let projectID):
                EditProjectView(
                    store: companionManager.projectStore,
                    projectID: projectID,
                    onRelocate: { [companionManager] pid, newLoc, moveFiles in
                        try companionManager.relocateProject(pid, to: newLoc, moveFiles: moveFiles)
                    },
                    screen: $screen
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            case .settings:
                SettingsView(
                    companionManager: companionManager,
                    screen: $screen
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            case .reviewSession(let sessionID):
                ReviewSessionView(
                    sessionStore: companionManager.sessionStore,
                    synthesisService: companionManager.synthesisService,
                    sessionID: sessionID,
                    onResynthesize: { [companionManager] session in
                        companionManager.triggerSynthesis(for: session)
                    },
                    screen: $screen
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            case .uploadDecision(let sessionID):
                UploadDecisionView(
                    sessionStore: companionManager.sessionStore,
                    sessionID: sessionID,
                    hasNUPAT: companionManager.hasNUPAT,
                    onSettings: { screen = .settings },
                    onUpload: { [companionManager] session in
                        await companionManager.uploadSession(session)
                    },
                    onQueue: { [companionManager] session in
                        companionManager.queueSession(session)
                    },
                    screen: $screen
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            case .outbox:
                OutboxView(
                    sessionStore: companionManager.sessionStore,
                    projectStore: companionManager.projectStore,
                    hasNUPAT: companionManager.hasNUPAT,
                    onUpload: { [companionManager] session in
                        await companionManager.uploadSession(session)
                    },
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
            HStack(spacing: 6) {
                ProjectPickerRow(
                    store: companionManager.projectStore,
                    screen: $screen
                )
                Button {
                    screen = .newProject
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                if let activeID = companionManager.projectStore.activeProjectID {
                    Button {
                        screen = .editProject(activeID)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                            .frame(width: 24, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
                if !companionManager.projectStore.projects.isEmpty {
                    Button {
                        screen = .manage
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                            .frame(width: 24, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .padding(.horizontal, 16)

            Spacer().frame(height: 10)
            displayRow
                .padding(.horizontal, 16)

            Spacer().frame(height: 8)
            audioInputRow
                .padding(.horizontal, 16)

            Spacer().frame(height: 8)
            cameraRow
                .padding(.horizontal, 16)

            Spacer().frame(height: 16)
            sessionSection
                .padding(.horizontal, 16)

            outboxBadgeRow
                .padding(.horizontal, 16)
        }

        Spacer().frame(height: 12)
    }

    @ViewBuilder
    private var outboxBadgeRow: some View {
        let count = companionManager.sessionStore.allOutboxSessions().count
        if count > 0 {
            Button {
                screen = .outbox
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "tray.full")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.warning)
                    Text("\(count) pending upload\(count == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(DS.Colors.warning.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .padding(.top, 8)
        }
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

            Button {
                screen = .settings
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .pointerCursor()

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

                Text("Press ⌃⌥D anywhere on your Mac to start recording a narrated screen clip; press again to stop. ⌃⌥V records a voice-only note (no screen). ⌃⌥M drops a marker on the moment you're capturing.")
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

    // MARK: - Display Selection

    private var displayRow: some View {
        let displays = companionManager.sessionManager.availableDisplays
        let selected = displays.first(where: { $0.id == companionManager.sessionManager.selectedDisplayID })

        return HStack(spacing: 8) {
            Text("DISPLAY")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)

            HStack(spacing: 4) {
                Image(systemName: "display")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                Text(selected?.name ?? "No display")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(selected == nil
                        ? DS.Colors.textTertiary
                        : DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if !displays.isEmpty {
                Button {
                    showScreenSelectionOverlay()
                } label: {
                    Text(displays.count > 1 ? "Change" : "Preview")
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

    private var cameraRow: some View {
        let manager = companionManager.cameraOverlayManager
        let cameras = manager.availableCameras
        let selected = cameras.first(where: { $0.id == manager.selectedCameraDeviceID })

        return HStack(spacing: 8) {
            Text("CAMERA")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)

            Toggle("", isOn: Binding(
                get: { manager.isEnabled },
                set: { manager.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()

            if manager.isEnabled {
                if cameras.count > 1 {
                    Menu {
                        ForEach(cameras) { camera in
                            Button {
                                manager.switchCamera(to: camera.id)
                            } label: {
                                if camera.id == manager.selectedCameraDeviceID {
                                    Label(camera.name, systemImage: "checkmark")
                                } else {
                                    Text(camera.name)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(selected?.name ?? "No camera")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(DS.Colors.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .pointerCursor()
                } else {
                    Text(selected?.name ?? "No camera")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(selected == nil
                            ? DS.Colors.textTertiary
                            : DS.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()
        }
    }

    private var audioInputRow: some View {
        let devices = companionManager.sessionManager.availableAudioDevices
        let selected = devices.first(where: { $0.id == companionManager.sessionManager.selectedAudioDeviceID })

        return HStack(spacing: 8) {
            Text("INPUT")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)

            HStack(spacing: 4) {
                Image(systemName: "mic")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)

                if devices.count > 1 {
                    Menu {
                        ForEach(devices) { device in
                            Button {
                                companionManager.sessionManager.selectedAudioDeviceID = device.id
                            } label: {
                                if device.id == companionManager.sessionManager.selectedAudioDeviceID {
                                    Label(device.name, systemImage: "checkmark")
                                } else {
                                    Text(device.name)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(selected?.name ?? "No input")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(selected == nil
                                    ? DS.Colors.textTertiary
                                    : DS.Colors.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(DS.Colors.textTertiary)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .pointerCursor()
                } else {
                    Text(selected?.name ?? "No input")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(selected == nil
                            ? DS.Colors.textTertiary
                            : DS.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()
        }
    }

    private func showScreenSelectionOverlay() {
        companionManager.screenSelectionOverlay.show(
            displays: companionManager.sessionManager.availableDisplays,
            currentSelection: companionManager.sessionManager.selectedDisplayID
        ) { [companionManager] selectedID in
            companionManager.sessionManager.selectedDisplayID = selectedID
            companionManager.cameraOverlayManager.moveToDisplay(selectedID)
        }
    }

    // MARK: - Session

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sessionStatusRow
            currentSessionBlock
        }
    }

    @ViewBuilder
    private var currentSessionBlock: some View {
        let sessions = companionManager.sessionStore.sessionsForActiveProject
        if let session = sessions.first {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if session.status == .open {
                        // Live indicator: signals "this session is
                        // accepting clips right now" at a glance,
                        // beyond just the label change.
                        Circle()
                            .fill(DS.Colors.success)
                            .frame(width: 6, height: 6)
                            .shadow(color: DS.Colors.success.opacity(0.6), radius: 3)
                    }
                    Text(session.status == .open ? "CURRENT SESSION" : "LAST SESSION")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .tracking(0.4)
                        .foregroundColor(DS.Colors.textTertiary)
                    Spacer()
                    if session.status == .open {
                        Button {
                            companionManager.sessionManager.endActiveSession()
                        } label: {
                            Text("End Session")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(DS.Colors.textOnAccent)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(DS.Colors.accent))
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                    }
                }

                let clips = clipsForSession(session)
                let preview = clips.suffix(3)
                if preview.isEmpty {
                    Text("Press ⌃⌥D to record a clip, or ⌃⌥V for a voice note.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(Array(preview)) { clip in
                        clipRow(clip)
                    }
                    if clips.count > preview.count {
                        Text("+ \(clips.count - preview.count) earlier in this session")
                            .font(.system(size: 10))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }

                synthesisIndicator(for: session)

                Button {
                    screen = .timeline
                } label: {
                    HStack(spacing: 4) {
                        Text(sessions.count > 1 ? "View all sessions (\(sessions.count))" : "View timeline")
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func synthesisIndicator(for session: YardTalkSession) -> some View {
        let isRunning: Bool = {
            if case .running(let sid) = companionManager.synthesisService.status, sid == session.id { return true }
            return false
        }()

        if isRunning {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Synthesizing…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.accent)
            }
            .padding(.vertical, 4)
        } else if session.synthesisError != nil, session.synthesisResult == nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.warning)
                    Text("Synthesis failed")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.warning)
                    Spacer()
                    Button {
                        companionManager.triggerSynthesis(for: session)
                    } label: {
                        Text("Retry")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.warning)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(DS.Colors.warning.opacity(0.10))
            )
            .padding(.top, 6)
        } else if session.status == .synthesized, let summary = session.synthesisResult?.summary {
            // Synthesized blockquote: the summary text is its own tap
            // target into Review (preserves the previous behavior),
            // and the action row underneath holds two pill
            // affordances — Review (matches the timeline's pill
            // exactly) and Push to NU (the new fast-path CTA, only
            // visible when a PAT is configured and the session is
            // eligible). Mirrors TimelineView so the synthesized
            // payload reads as the same kind of object on both
            // screens.
            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(DS.Colors.accent.opacity(0.55))
                    .frame(width: 2)
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        screen = .reviewSession(session.id)
                    } label: {
                        Text(summary)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineSpacing(1.5)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()

                    HStack(spacing: 6) {
                        reviewPill(sessionID: session.id)
                        PushToNUAffordance(
                            session: session,
                            hasNUPAT: companionManager.hasNUPAT,
                            onUpload: { [companionManager] s in
                                await companionManager.uploadSession(s)
                            }
                        )
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                Spacer(minLength: 0)
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.03))
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.top, 2)
        }
    }

    private func clipsForSession(_ session: YardTalkSession) -> [YardTalkClip] {
        companionManager.clipStore.clipsForActiveProject
            .filter { $0.sessionID == session.id }
            .sorted(by: { $0.recordedAt < $1.recordedAt })
    }

    /// Mirror of the timeline's Review pill (TimelineView.swift) so
    /// the affordance is identical wherever a synthesized session
    /// appears. Pair with PushToNUAffordance for the full action row.
    private func reviewPill(sessionID: UUID) -> some View {
        Button {
            screen = .reviewSession(sessionID)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "pencil")
                    .font(.system(size: 9, weight: .semibold))
                Text("Review")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(DS.Colors.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .stroke(DS.Colors.accent.opacity(0.5), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    @ViewBuilder
    private var sessionStatusRow: some View {
        switch companionManager.sessionManager.status {
        case .idle:
            HStack(spacing: 8) {
                Image(systemName: "circle")
                    .foregroundColor(DS.Colors.textTertiary)
                    .font(.system(size: 9, weight: .semibold))
                Text("⌃⌥D to record · ⌃⌥V for voice note · ⌃⌥M to mark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
            }
        case .recording:
            let isVoice = companionManager.sessionManager.isAudioOnlyRecording
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: isVoice ? "mic.fill" : "circle.fill")
                        .foregroundColor(isVoice ? DS.Colors.accent : .red)
                        .font(.system(size: 9))
                    Text(isVoice ? "Recording voice note…" : "Recording…")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    if companionManager.sessionManager.inFlightMarkerCount > 0 {
                        Text("· \(companionManager.sessionManager.inFlightMarkerCount) marker\(companionManager.sessionManager.inFlightMarkerCount == 1 ? "" : "s")")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.accent)
                    }
                    Spacer()
                    AudioLevelMeter(level: companionManager.sessionManager.audioLevel)
                        .frame(width: 80, height: 6)
                }
                if let warning = companionManager.sessionManager.audioWarning {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(DS.Colors.warning)
                        Text(warning)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(DS.Colors.warning)
                    }
                }
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

    private func clipRow(_ clip: YardTalkClip) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(clip.recordedAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Text("\(Int(clip.durationSeconds.rounded()))s")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                if clip.audioOnly {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 9))
                        .foregroundColor(DS.Colors.accent)
                        .help("Voice note (audio only)")
                }
                if !clip.markers.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(Array(clip.markers.prefix(3).enumerated()), id: \.offset) { _, _ in
                            Circle()
                                .fill(DS.Colors.accent)
                                .frame(width: 4, height: 4)
                        }
                        if clip.markers.count > 3 {
                            Text("+\(clip.markers.count - 3)")
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .foregroundColor(DS.Colors.accent)
                        }
                    }
                }
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
        if clip.transcriptionError != nil {
            HStack(spacing: 6) {
                Text("Transcription failed")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.warning)
                Spacer()
                Button {
                    companionManager.sessionManager.retryTranscription(for: clip)
                } label: {
                    Text("Retry")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Colors.accent)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                Button {
                    companionManager.clipStore.delete(clip)
                } label: {
                    Text("Delete")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(red: 0.85, green: 0.3, blue: 0.3))
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
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
                    .truncationMode(.tail)
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
