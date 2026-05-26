//
//  UploadDecisionView.swift
//  yardtalk
//
//  M5 — three-way decision dialog reached from "Accept & Continue" in
//  the review screen. Embodies the locked principle from CLAUDE.md:
//  "Nothing leaves without an explicit, recent user decision."
//
//  • Upload Now — POST to NU. On success, navigate to the timeline
//    where the session now shows an "Uploaded" badge. On failure,
//    surface the error inline with a Retry button — staying on this
//    screen is intentional so the user knows the upload didn't land.
//  • Queue for Later — flag the session so M6's outbox picks it up,
//    return to the timeline. No network call.
//  • Keep Local — leave the upload state untouched, return to the
//    timeline. Synthesis stays on disk forever; the user can always
//    come back and upload later.
//
//  In Debug builds the payload's `test_mode` is true (per
//  NUSessionPayload.defaultTestMode) and that's surfaced inline so
//  the user can see they're hitting the dev surface, not prod.
//

import SwiftUI

struct UploadDecisionView: View {
    let sessionStore: SessionStore
    let sessionID: UUID
    let hasNUPAT: Bool
    let onSettings: () -> Void
    let onUpload: (YardTalkSession) async -> Void
    let onQueue: (YardTalkSession) -> Void
    @Binding var screen: ProjectPickerScreen

    @State private var isUploading = false

    private var session: YardTalkSession? {
        sessionStore.sessionsForActiveProject.first(where: { $0.id == sessionID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            backRow
                .padding(.bottom, 10)

            if let session, let payload = session.synthesisResult {
                content(session: session, payload: payload)
            } else {
                missingPayloadState
            }
        }
    }

    private var backRow: some View {
        HStack {
            Button {
                screen = .reviewSession(sessionID)
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
            #if DEBUG
            Text("TEST MODE")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundColor(DS.Colors.warning)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(DS.Colors.warning.opacity(0.14)))
            #endif
        }
    }

    private var missingPayloadState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing to upload")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text("This session has no synthesis output. Synthesize first via the timeline.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func content(session: YardTalkSession, payload: NUSessionPayload) -> some View {
        Text("Send to NU?")
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.bottom, 2)

        Text("Pick how this session should be sent to your NeighborhoodUnited assistant. Clips and transcripts always stay on this device — only the structured payload below is uploaded.")
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 12)

        payloadPreview(payload: payload)
            .padding(.bottom, 12)

        if !hasNUPAT {
            patHint
                .padding(.bottom, 12)
        }

        if let error = session.uploadState.errorMessage,
           session.uploadState.kind == .failed {
            uploadFailedChip(error: error)
                .padding(.bottom, 12)
        }

        actions(session: session)
    }

    private var patHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "key")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("NU PAT not configured")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.warning)
                Text("Add it in Settings to enable Upload Now.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            Button {
                onSettings()
            } label: {
                Text("Settings")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.warning)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(DS.Colors.warning.opacity(0.10))
        )
    }

    private func uploadFailedChip(error: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.warning)
            Text(error)
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.warning)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(DS.Colors.warning.opacity(0.10))
        )
    }

    @ViewBuilder
    private func payloadPreview(payload: NUSessionPayload) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Payload preview")
            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(DS.Colors.accent.opacity(0.55))
                    .frame(width: 2)
                VStack(alignment: .leading, spacing: 6) {
                    metaRow(label: "Project", value: payload.project)
                    metaRow(label: "Type", value: payload.projectType)
                    metaRow(label: "Started", value: payload.sessionStart.formatted(date: .abbreviated, time: .shortened))
                    Divider().background(DS.Colors.borderSubtle)
                    Text(payload.summary)
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineSpacing(2)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                    metaRow(label: "Items",
                            value: "\(payload.accomplishments.count) acc · \(payload.blockers.count) blockers · \(payload.nextSteps.count) next")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func metaRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .tracking(0.4)
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func actions(session: YardTalkSession) -> some View {
        VStack(spacing: 8) {
            uploadNowButton(session: session)
            queueButton(session: session)
            keepLocalButton
        }
    }

    private func uploadNowButton(session: YardTalkSession) -> some View {
        Button {
            Task { @MainActor in
                isUploading = true
                await onUpload(session)
                isUploading = false
                // Navigate to timeline only on success — on failure
                // the session.uploadState.errorMessage is set, the
                // user stays here with the inline retry context.
                if let updated = self.session,
                   updated.uploadState.kind == .uploaded {
                    screen = .timeline
                }
            }
        } label: {
            HStack(spacing: 6) {
                if isUploading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(DS.Colors.textOnAccent)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(isUploading
                     ? "Uploading…"
                     : (session.uploadState.kind == .failed ? "Retry Upload" : "Upload Now"))
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(DS.Colors.textOnAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill((hasNUPAT && !isUploading) ? DS.Colors.accent : DS.Colors.accent.opacity(0.4))
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(!hasNUPAT || isUploading)
    }

    private func queueButton(session: YardTalkSession) -> some View {
        Button {
            onQueue(session)
            screen = .timeline
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.system(size: 11, weight: .semibold))
                Text("Queue for Later")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(DS.Colors.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(isUploading)
    }

    private var keepLocalButton: some View {
        Button {
            screen = .timeline
        } label: {
            Text("Keep Local Only")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(isUploading)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .tracking(0.4)
            .foregroundColor(DS.Colors.textTertiary)
    }
}
