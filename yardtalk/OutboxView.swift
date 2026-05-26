//
//  OutboxView.swift
//  yardtalk
//
//  Cross-project list of sessions with queued or failed NU uploads.
//  "Upload" per-session and "Upload All" at the top. No auto-upload —
//  every push is an explicit user decision.
//

import SwiftUI

struct OutboxView: View {
    let sessionStore: SessionStore
    let projectStore: ProjectStore
    let hasNUPAT: Bool
    let onUpload: (YardTalkSession) async -> Void
    @Binding var screen: ProjectPickerScreen

    @State private var sessions: [YardTalkSession] = []
    @State private var uploadingAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            backRow

            HStack {
                Text("Outbox")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                if sessions.count > 1 {
                    Button {
                        uploadAll()
                    } label: {
                        HStack(spacing: 4) {
                            if uploadingAll {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("Upload All")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(hasNUPAT ? DS.Colors.accent : DS.Colors.accent.opacity(0.4)))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    .disabled(!hasNUPAT || uploadingAll)
                }
            }

            if !hasNUPAT {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.warning)
                    Text("Add a NU PAT in Settings to upload.")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.warning)
                }
            }

            if sessions.isEmpty {
                Text("No queued or failed uploads.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.vertical, 8)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(sessions) { session in
                            outboxRow(session)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .onAppear { reload() }
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

    private func outboxRow(_ session: YardTalkSession) -> some View {
        let projectName = projectStore.projects.first(where: { $0.id == session.projectID })?.name ?? "Unknown"

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(projectName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Spacer()
                uploadStateBadge(session.uploadState)
            }

            HStack {
                Text("\(session.clipIDs.count) clip\(session.clipIDs.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)

                if let summary = session.synthesisResult?.summary {
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                if hasNUPAT {
                    OutboxUploadButton(session: session, onUpload: { s in
                        await onUpload(s)
                        reload()
                    })
                }
            }

            if let error = session.uploadState.errorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.warning)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    @ViewBuilder
    private func uploadStateBadge(_ state: UploadState) -> some View {
        switch state.kind {
        case .queued:
            HStack(spacing: 4) {
                Circle()
                    .fill(DS.Colors.accent)
                    .frame(width: 6, height: 6)
                Text("Queued")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.accent)
            }
        case .failed:
            HStack(spacing: 4) {
                Circle()
                    .fill(DS.Colors.warning)
                    .frame(width: 6, height: 6)
                Text("Failed")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.warning)
            }
        default:
            EmptyView()
        }
    }

    private func reload() {
        sessions = sessionStore.allOutboxSessions()
    }

    private func uploadAll() {
        guard hasNUPAT else { return }
        uploadingAll = true
        let toUpload = sessions
        Task { @MainActor in
            for session in toUpload {
                await onUpload(session)
            }
            reload()
            uploadingAll = false
        }
    }
}

private struct OutboxUploadButton: View {
    let session: YardTalkSession
    let onUpload: (YardTalkSession) async -> Void
    @State private var isUploading = false

    var body: some View {
        Button {
            isUploading = true
            Task { @MainActor in
                await onUpload(session)
                isUploading = false
            }
        } label: {
            HStack(spacing: 4) {
                if isUploading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(session.uploadState.kind == .failed ? "Retry" : "Upload")
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
        .disabled(isUploading)
    }
}
