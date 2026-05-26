//
//  PushToNUAffordance.swift
//  yardtalk
//
//  Reusable fast-path CTA: when a synthesized session is eligible for
//  upload (PAT configured + not yet uploaded or last attempt failed),
//  show a tasteful pill that drives the existing
//  CompanionManager.uploadSession(_:) flow with a two-step inline
//  confirm. Lives both in the main panel's synthesis blockquote and
//  in each timeline session card so the affordance is consistent
//  wherever a synthesized session is visible.
//
//  Three internal states drive the rendering:
//    1. idle      → Push pill ("Push to NU" or "Retry push" if last
//                   attempt failed)
//    2. pending   → inline confirm row (Cancel + Push)
//    3. uploading → spinner + "Pushing…"
//
//  When the upload succeeds, `session.uploadState.kind` flips to
//  `.uploaded` and the eligibility check returns false — the
//  component renders nothing and the timeline / panel badge becomes
//  the source of truth ("Uploaded"). On failure the badge becomes
//  "Upload failed" and the pill reappears in retry mode so the user
//  can try again without leaving their current screen.
//

import SwiftUI

struct PushToNUAffordance: View {
    let session: YardTalkSession
    let hasNUPAT: Bool
    let onUpload: (YardTalkSession) async -> Void

    @State private var pendingConfirm = false
    @State private var isUploading = false

    private var isEligible: Bool {
        guard hasNUPAT else { return false }
        guard session.synthesisResult != nil else { return false }
        switch session.uploadState.kind {
        case .notUploaded, .failed:
            return true
        case .queued, .uploading, .uploaded:
            return false
        }
    }

    private var isRetry: Bool {
        session.uploadState.kind == .failed
    }

    var body: some View {
        if session.uploadState.kind == .uploaded {
            uploadedBadge
        } else if isEligible {
            if isUploading {
                pushingRow
            } else if pendingConfirm {
                confirmRow
            } else {
                pushPill
            }
        }
    }

    // MARK: - States

    private var pushPill: some View {
        Button {
            pendingConfirm = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text(isRetry ? "Retry push" : "Push to NU")
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

    private var confirmRow: some View {
        HStack(spacing: 4) {
            Button {
                pendingConfirm = false
            } label: {
                Text("Cancel")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            Button {
                runUpload()
            } label: {
                Text(isRetry ? "Retry" : "Push")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(DS.Colors.accent))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    private var pushingRow: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Pushing…")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.accent)
        }
    }

    private var uploadedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 9, weight: .semibold))
            Text("Sent to NU")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(DS.Colors.success)
    }

    private func runUpload() {
        pendingConfirm = false
        isUploading = true
        // The captured session value is used by uploadSession to
        // build the request and stamp the idempotency key. The async
        // call returns when the lifecycle completes (uploaded/failed
        // already persisted via sessionStore.update). We then drop
        // isUploading so the pill (or nothing) shows again, with the
        // updated session reflected via @Observable.
        Task { @MainActor in
            await onUpload(session)
            isUploading = false
        }
    }
}
