//
//  TimelineView.swift
//  yardtalk
//
//  Full per-project session history. Each session is a card with a header
//  (time range, clip count, status badge) and a list of its clips. Tapping
//  a clip expands the row in place to show the full transcript and an
//  "Open Video" affordance — sheets and modals misbehave inside a non-
//  activating NSPanel, so expansion must stay within the parent screen
//  swap.
//

import AppKit
import SwiftUI

struct TimelineView: View {
    let sessionStore: SessionStore
    let clipStore: ClipStore
    let synthesisService: SynthesisService
    let videoURL: (YardTalkClip) -> URL?
    let onSynthesize: (YardTalkSession) -> Void
    let hasNUPAT: Bool
    let onUpload: (YardTalkSession) async -> Void
    @Binding var screen: ProjectPickerScreen
    @State private var expandedClipID: UUID?
    @State private var pendingDeleteClipID: UUID?
    @State private var pendingDeleteSessionID: UUID?
    @State private var expandedSynthesisSessionID: UUID?

    private var sessions: [YardTalkSession] {
        sessionStore.sessionsForActiveProject
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            backRow
            Text("Timeline")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            if sessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(sessions) { session in
                            sessionCard(session)
                        }
                    }
                    .padding(.bottom, 4)
                }
                .frame(maxHeight: 360)
            }
        }
    }

    private var backRow: some View {
        HStack {
            Button {
                screen = .main
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            Spacer()
        }
    }

    private var emptyState: some View {
        Text("No sessions yet. Hit ⌃⌥D to record your first clip.")
            .font(.system(size: 12))
            .foregroundColor(DS.Colors.textTertiary)
            .padding(.vertical, 12)
    }

    private func sessionCard(_ session: YardTalkSession) -> some View {
        let clips = clipsForSession(session)
        return VStack(alignment: .leading, spacing: 8) {
            sessionHeader(session, clipCount: clips.count)
            if clips.isEmpty {
                Text("Empty session")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            } else {
                VStack(spacing: 6) {
                    ForEach(clips) { clip in
                        clipRow(clip, sessionStart: session.startedAt)
                    }
                }
            }
            synthesisSection(for: session)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private func sessionHeader(_ session: YardTalkSession, clipCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(rangeSubtitle(session, clipCount: clipCount))
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()
                statusBadge(session)
                if session.status != .open {
                    Button {
                        pendingDeleteSessionID = pendingDeleteSessionID == session.id ? nil : session.id
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }

            if pendingDeleteSessionID == session.id {
                sessionDeleteConfirmRow(session, clipCount: clipCount)
            }
        }
    }

    private func sessionDeleteConfirmRow(_ session: YardTalkSession, clipCount: Int) -> some View {
        HStack(spacing: 8) {
            Text("Delete session and \(clipCount) clip\(clipCount == 1 ? "" : "s")?")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
            Spacer()
            Button {
                pendingDeleteSessionID = nil
            } label: {
                Text("Cancel")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button {
                deleteSession(session)
            } label: {
                Text("Delete")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color(red: 0.85, green: 0.3, blue: 0.3)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    private func deleteSession(_ session: YardTalkSession) {
        let clips = clipsForSession(session)
        for clip in clips {
            clipStore.delete(clip)
        }
        sessionStore.delete(session)
        pendingDeleteSessionID = nil
        expandedClipID = nil
    }

    private func rangeSubtitle(_ session: YardTalkSession, clipCount: Int) -> String {
        let clipText = "\(clipCount) clip\(clipCount == 1 ? "" : "s")"
        if let endedAt = session.endedAt {
            let duration = endedAt.timeIntervalSince(session.startedAt)
            return "\(clipText) · \(formatDuration(duration))"
        }
        return clipText
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        if m < 1 { return "<1m" }
        if m < 60 { return "\(m)m" }
        return String(format: "%dh %dm", m / 60, m % 60)
    }

    @ViewBuilder
    private func synthesisSection(for session: YardTalkSession) -> some View {
        let isRunning: Bool = {
            if case .running(let sid) = synthesisService.status, sid == session.id { return true }
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
            .padding(.top, 4)
        }

        if let payload = session.synthesisResult {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    expandedSynthesisSessionID = expandedSynthesisSessionID == session.id ? nil : session.id
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(DS.Colors.accent)
                        Text("Summary")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Colors.accent)
                        Image(systemName: expandedSynthesisSessionID == session.id ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()

                if expandedSynthesisSessionID == session.id {
                    HStack(alignment: .top, spacing: 0) {
                        Rectangle()
                            .fill(DS.Colors.accent.opacity(0.55))
                            .frame(width: 2)
                        Text(payload.summary)
                            .font(.system(size: 11))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.03))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }

                HStack(spacing: 6) {
                    Button {
                        screen = .reviewSession(session.id)
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

                    PushToNUAffordance(
                        session: session,
                        hasNUPAT: hasNUPAT,
                        onUpload: onUpload
                    )

                    Spacer()
                }
            }
            .padding(.top, 6)
        }

        if !isRunning, session.synthesisResult == nil, let error = session.synthesisError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.warning)
                Text("Synthesis failed")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.warning)
                Spacer()
                Button {
                    onSynthesize(session)
                } label: {
                    Text("Retry")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.warning)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(DS.Colors.warning.opacity(0.10))
            )
            .help(error)
            .padding(.top, 6)
        }

        if !isRunning && session.synthesisError == nil && session.synthesisResult == nil && session.status == .ended {
            Button {
                onSynthesize(session)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Synthesize Now")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(DS.Colors.accent))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func statusBadge(_ session: YardTalkSession) -> some View {
        // Upload state takes precedence once it leaves `.notUploaded`
        // — once a session has been uploaded (or is queued, failed,
        // etc.) that's the more relevant status for the user. Falls
        // back to the synthesis lifecycle state otherwise.
        switch session.uploadState.kind {
        case .uploaded:
            badge(text: "Uploaded", color: DS.Colors.success)
        case .uploading:
            badge(text: "Uploading", color: DS.Colors.accent)
        case .queued:
            badge(text: "Queued", color: DS.Colors.warning)
        case .failed:
            // Tappable: jump straight back into the decision dialog
            // for a one-click retry. Saves the user a Review hop.
            Button {
                screen = .uploadDecision(session.id)
            } label: {
                badge(text: "Upload failed", color: DS.Colors.destructive)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Tap to retry upload")
        case .notUploaded:
            switch session.status {
            case .open:
                badge(text: "Open", color: DS.Colors.success)
            case .ended:
                badge(text: "Ended", color: DS.Colors.textTertiary)
            case .synthesized:
                badge(text: "Synthesized", color: DS.Colors.accent)
            }
        }
    }

    private func badge(text: String, color: Color) -> some View {
        // Fill-only — the previous stroke + fill combo read as two
        // visual layers competing for attention. A flat tinted pill is
        // calmer and reads correctly even at 9pt.
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .tracking(0.4)
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
    }

    private func clipRow(_ clip: YardTalkClip, sessionStart: Date) -> some View {
        let isExpanded = expandedClipID == clip.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Button {
                    expandedClipID = isExpanded ? nil : clip.id
                } label: {
                    HStack(spacing: 8) {
                        Text(formatRelativeOffset(clip.recordedAt.timeIntervalSince(sessionStart)))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(DS.Colors.textTertiary)
                            .frame(width: 32, alignment: .leading)
                        transcriptSnippet(clip)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        durationBadge(clip)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Button {
                    pendingDeleteClipID = pendingDeleteClipID == clip.id ? nil : clip.id
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            if pendingDeleteClipID == clip.id && !isExpanded {
                clipDeleteConfirmRow(clip)
            }

            if isExpanded {
                expandedDetail(clip)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        // Calmer inset than the prior `black@0.18` — that read as a
        // hard-edged trough on the parent card. A light fill on a thin
        // border keeps the visual nesting without the hole-in-the-card
        // feel.
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
        )
    }

    private func formatRelativeOffset(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func durationBadge(_ clip: YardTalkClip) -> some View {
        HStack(spacing: 3) {
            Text("\(Int(clip.durationSeconds.rounded()))s")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(DS.Colors.textSecondary)
            // Marker ticks: cheap visual signal for "this clip has notable
            // moments" without a full timeline scrubber. Capped at 4 to
            // avoid overflowing a 320pt panel.
            ForEach(Array(clip.markers.prefix(4).enumerated()), id: \.offset) { _, _ in
                Circle()
                    .fill(DS.Colors.accent)
                    .frame(width: 4, height: 4)
            }
            if clip.markers.count > 4 {
                Text("+\(clip.markers.count - 4)")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(DS.Colors.accent)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    @ViewBuilder
    private func transcriptSnippet(_ clip: YardTalkClip) -> some View {
        if let error = clip.transcriptionError {
            Text("Transcription failed")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.warning)
                .lineLimit(1)
                .help(error)
        } else if let transcript = clip.transcript {
            if transcript.isEmpty {
                Text("(empty)")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            } else {
                Text(transcript)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
            }
        } else {
            Text("Transcribing…")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func expandedDetail(_ clip: YardTalkClip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().background(DS.Colors.borderSubtle)

            if let error = clip.transcriptionError {
                Text("Transcription failed: \(error)")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let transcript = clip.transcript, !transcript.isEmpty {
                Text(transcript)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else if clip.transcript?.isEmpty == true {
                Text("No speech detected.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            } else {
                Text("Transcribing…")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            if !clip.markers.isEmpty {
                Text(markersSummary(clip.markers))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(DS.Colors.accent)
            }

            if let url = videoURL(clip) {
                videoButtons(url: url)
            }
        }
        .padding(.top, 4)
    }

    private func clipDeleteConfirmRow(_ clip: YardTalkClip) -> some View {
        HStack(spacing: 8) {
            Text("Delete this clip?")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
            Spacer()
            Button {
                pendingDeleteClipID = nil
            } label: {
                Text("Cancel")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button {
                deleteClip(clip)
            } label: {
                Text("Delete")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color(red: 0.85, green: 0.3, blue: 0.3)))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    private func deleteClip(_ clip: YardTalkClip) {
        clipStore.delete(clip)
        if var session = sessionStore.sessionsForActiveProject.first(where: { $0.id == clip.sessionID }) {
            session.clipIDs.removeAll(where: { $0 == clip.id })
            try? sessionStore.update(session)
        }
        expandedClipID = nil
        pendingDeleteClipID = nil
    }

    private func videoButtons(url: URL) -> some View {
        HStack(spacing: 8) {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Open Video")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(DS.Colors.accent))
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Reveal")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().stroke(DS.Colors.borderSubtle, lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .pointerCursor()
            Spacer()
        }
    }

    private func markersSummary(_ markers: [TimeInterval]) -> String {
        let formatted = markers.map { String(format: "%.1fs", $0) }
        return "Markers: \(formatted.joined(separator: ", "))"
    }

    private func clipsForSession(_ session: YardTalkSession) -> [YardTalkClip] {
        clipStore.clipsForActiveProject
            .filter { $0.sessionID == session.id }
            .sorted(by: { $0.recordedAt < $1.recordedAt })
    }
}
