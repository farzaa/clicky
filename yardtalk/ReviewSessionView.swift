//
//  ReviewSessionView.swift
//  yardtalk
//
//  M3 — review and edit the four AI-generated fields of a session's
//  synthesis output before it leaves the device. Three actions:
//
//  • Accept & Continue — saves edits and returns to the previous screen.
//    Once M5 lands, this transitions to the upload-decision dialog.
//  • Re-synthesize — discards edits and runs a fresh Claude call. If the
//    user has unsaved edits, the button shifts into a two-step
//    confirmation per the locked decision ("Re-synthesize discards your
//    edits — continue?") so a stray click can't nuke careful editing.
//  • Discard — clears the synthesis output entirely and flips the
//    session back to `.ended` (still recoverable via "Synthesize Now"
//    from the timeline). Two-step destructive.
//
//  Edits autosave on disappear — Back / closing the panel persists
//  whatever's in the form. Live save on every keystroke would create
//  excessive disk writes for marginal benefit; a single write at exit
//  matches how the rest of the stores already mutate (one save per
//  user gesture).
//
//  When `synthesisResult` mutates while this view is on screen
//  (e.g., a Re-synthesize completes), the local fields reload from the
//  new payload via `.onChange`. Edits in flight at that moment are
//  intentionally clobbered — the user opted into re-synthesis.
//

import AppKit
import SwiftUI

struct ReviewSessionView: View {
    let sessionStore: SessionStore
    let synthesisService: SynthesisService
    let sessionID: UUID
    let onResynthesize: (YardTalkSession) -> Void
    @Binding var screen: ProjectPickerScreen

    @State private var summary: String = ""
    @State private var accomplishments: [String] = []
    @State private var blockers: [String] = []
    @State private var nextSteps: [String] = []
    @State private var hasLoaded = false
    @State private var hasEdits = false
    @State private var pendingResynthesizeConfirm = false
    @State private var pendingDiscardConfirm = false

    private var session: YardTalkSession? {
        sessionStore.sessionsForActiveProject.first(where: { $0.id == sessionID })
    }

    private var isResynthesizing: Bool {
        if case .running(let sid) = synthesisService.status, sid == sessionID { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            backRow
                .padding(.bottom, 10)

            if let session = session, session.synthesisResult != nil {
                content(for: session)
            } else {
                emptyState
            }
        }
        .onAppear { loadFromSession() }
        .onDisappear { saveIfDirty() }
        .onChange(of: session?.synthesisResult) { _, _ in
            // Re-synthesize completed (or other external mutation).
            // Reload local state so the user sees the new payload.
            loadFromSession(force: true)
        }
    }

    // MARK: - Header

    private var backRow: some View {
        HStack(spacing: 6) {
            Button {
                screen = .timeline
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

            if hasEdits {
                Text("UNSAVED")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(0.6)
                    .foregroundColor(DS.Colors.warning)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(DS.Colors.warning.opacity(0.14)))
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No synthesis to review")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text("This session hasn't been synthesized yet, or the synthesis was discarded. Use \"Synthesize Now\" from the timeline to generate a payload.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(for session: YardTalkSession) -> some View {
        Text("Review & Edit")
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.bottom, 2)

        Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
            .padding(.bottom, 12)

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summaryEditor
                listEditor(
                    label: "Accomplishments",
                    placeholder: "What got done?",
                    items: $accomplishments
                )
                listEditor(
                    label: "Blockers",
                    placeholder: "Open questions or weak spots?",
                    items: $blockers
                )
                listEditor(
                    label: "Next steps",
                    placeholder: "Concrete follow-ups?",
                    items: $nextSteps
                )
            }
            .padding(.bottom, 12)
        }
        .frame(maxHeight: 320)

        Divider()
            .background(DS.Colors.borderSubtle)
            .padding(.vertical, 10)

        actions(for: session)
    }

    // MARK: - Summary editor

    private var summaryEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Summary")
            // Blockquote container mirrors the Timeline / panel preview
            // treatment so editing feels like editing the artifact, not
            // a generic form field.
            HStack(alignment: .top, spacing: 0) {
                Rectangle()
                    .fill(DS.Colors.accent.opacity(0.55))
                    .frame(width: 2)

                TextField("1–3 sentence overview…", text: $summary, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineSpacing(2)
                    .lineLimit(2...8)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .onChange(of: summary) { _, _ in markEdited() }
            }
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    // MARK: - List editor

    private func listEditor(
        label: String,
        placeholder: String,
        items: Binding<[String]>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(label)

            if items.wrappedValue.isEmpty {
                Text("None")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 4) {
                    ForEach(items.wrappedValue.indices, id: \.self) { idx in
                        listRow(
                            placeholder: placeholder,
                            text: items[idx],
                            onRemove: {
                                guard idx < items.wrappedValue.count else { return }
                                items.wrappedValue.remove(at: idx)
                                markEdited()
                            }
                        )
                    }
                }
            }

            Button {
                items.wrappedValue.append("")
                markEdited()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Add item")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(DS.Colors.accent)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .padding(.top, 2)
        }
    }

    private func listRow(
        placeholder: String,
        text: Binding<String>,
        onRemove: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(DS.Colors.textTertiary.opacity(0.6))
                .frame(width: 4, height: 4)
                .padding(.top, 9)

            TextField(placeholder, text: text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1...4)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
                .onChange(of: text.wrappedValue) { _, _ in markEdited() }

            Button(action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .padding(.top, 6)
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func actions(for session: YardTalkSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Primary: Accept & Continue → upload decision dialog (M5)
            Button {
                save()
                screen = .uploadDecision(sessionID)
            } label: {
                HStack {
                    Spacer()
                    Text("Accept & Continue")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DS.Colors.accent)
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(isResynthesizing)
            .opacity(isResynthesizing ? 0.5 : 1)

            // Secondary row: Re-synthesize + Discard
            HStack(spacing: 8) {
                resynthesizeButton(for: session)
                discardButton(for: session)
            }

            if isResynthesizing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Re-synthesizing…")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.accent)
                }
                .padding(.top, 2)
            }
        }
    }

    @ViewBuilder
    private func resynthesizeButton(for session: YardTalkSession) -> some View {
        if pendingResynthesizeConfirm {
            inlineConfirmRow(
                message: hasEdits ? "Discard edits & re-synthesize?" : "Re-synthesize?",
                confirmLabel: "Re-synthesize",
                confirmColor: DS.Colors.accent,
                onCancel: { pendingResynthesizeConfirm = false },
                onConfirm: {
                    pendingResynthesizeConfirm = false
                    pendingDiscardConfirm = false
                    onResynthesize(session)
                }
            )
        } else {
            Button {
                pendingDiscardConfirm = false
                pendingResynthesizeConfirm = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Re-synthesize")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(isResynthesizing)
        }
    }

    @ViewBuilder
    private func discardButton(for session: YardTalkSession) -> some View {
        if pendingDiscardConfirm {
            // Explicit copy: name the artifact being deleted and say
            // what survives. The earlier "Discard?" wording read as
            // "discard my edits" and surprised the user when it nuked
            // the entire synthesis. The fact that clips + transcripts
            // remain — and that Synthesize Now can rebuild — is the
            // important reassurance.
            inlineConfirmRow(
                message: "Delete synthesis? Clips stay, you can rebuild.",
                confirmLabel: "Delete",
                confirmColor: DS.Colors.destructive,
                onCancel: { pendingDiscardConfirm = false },
                onConfirm: {
                    pendingDiscardConfirm = false
                    pendingResynthesizeConfirm = false
                    discard(session: session)
                }
            )
        } else {
            Button {
                pendingResynthesizeConfirm = false
                pendingDiscardConfirm = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Delete Synthesis")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(DS.Colors.destructiveText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DS.Colors.destructive.opacity(0.5), lineWidth: 0.8)
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(isResynthesizing)
            .help("Delete the Claude-generated payload. Clips and transcripts remain on disk; you can rebuild with Synthesize Now from the timeline.")
        }
    }

    private func inlineConfirmRow(
        message: String,
        confirmLabel: String,
        confirmColor: Color,
        onCancel: @escaping () -> Void,
        onConfirm: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Text(message)
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button(action: onCancel) {
                Text("Cancel")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            Button(action: onConfirm) {
                Text(confirmLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(confirmColor))
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
        )
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .tracking(0.4)
            .foregroundColor(DS.Colors.textTertiary)
    }

    private func loadFromSession(force: Bool = false) {
        guard let payload = session?.synthesisResult else { return }
        if hasLoaded && !force { return }
        summary = payload.summary
        accomplishments = payload.accomplishments
        blockers = payload.blockers
        nextSteps = payload.nextSteps
        hasLoaded = true
        hasEdits = false
    }

    private func markEdited() {
        guard hasLoaded else { return }
        if !hasEdits { hasEdits = true }
    }

    private func saveIfDirty() {
        guard hasEdits else { return }
        save()
    }

    private func save() {
        guard var current = session, var payload = current.synthesisResult else { return }
        payload.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        payload.accomplishments = trimmed(accomplishments)
        payload.blockers = trimmed(blockers)
        payload.nextSteps = trimmed(nextSteps)
        current.synthesisResult = payload
        try? sessionStore.update(current)
        hasEdits = false
    }

    private func trimmed(_ items: [String]) -> [String] {
        items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func discard(session: YardTalkSession) {
        var updated = session
        updated.synthesisResult = nil
        updated.synthesisError = nil
        updated.status = .ended
        try? sessionStore.update(updated)
        hasEdits = false
        screen = .timeline
    }
}
