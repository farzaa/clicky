//
//  DictationHistoryPanelView.swift
//  leanring-buddy
//
//  In-panel view for the local dictation history. Lists recent push-to-talk
//  transcripts (newest first) with Copy / Insert / Ask again / Delete actions,
//  plus the on/off toggle and retention controls. Everything shown here is
//  stored only on this Mac — the view says so up front.
//

import SwiftUI

// MARK: - Entry Row In The Main Panel

/// The "History" row shown in the main companion panel. Opens the history view
/// and warns when the most recent message didn't go through.
struct DictationHistoryPanelRow: View {
    @ObservedObject var dictationHistoryStore: DictationHistoryStore
    let onOpenHistory: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onOpenHistory) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(mostRecentMessageNeedsAttention ? DS.Colors.warning : DS.Colors.textTertiary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text("History")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isHovered ? DS.Colors.textPrimary : DS.Colors.textSecondary)

                    Text(subtitleText)
                        .font(.system(size: 10))
                        .foregroundColor(mostRecentMessageNeedsAttention ? DS.Colors.warningText : DS.Colors.textTertiary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(isHovered ? DS.Colors.textSecondary : DS.Colors.textTertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
    }

    private var mostRecentMessageNeedsAttention: Bool {
        guard let mostRecentEntry = dictationHistoryStore.entries.first else { return false }
        return mostRecentEntry.status == .failed || mostRecentEntry.status == .interrupted
    }

    private var subtitleText: String {
        if !dictationHistoryStore.isHistoryEnabled {
            return "Off"
        }
        if mostRecentMessageNeedsAttention {
            return "Your last message didn't go through"
        }
        return "Saved only on this Mac"
    }
}

// MARK: - History View

struct DictationHistoryPanelView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var dictationHistoryStore: DictationHistoryStore
    let onBackButtonPressed: () -> Void

    /// The entry whose text was just copied, so its Copy button can briefly say "Copied".
    @State private var recentlyCopiedEntryID: UUID?
    /// Set when Insert had to fall back to copying because Accessibility is missing.
    @State private var entryIDCopiedBecauseInsertWasUnavailable: UUID?
    /// "Clear all" is irreversible, so it asks for an inline confirmation first.
    @State private var isConfirmingClearAll = false

    private static let maximumEntriesListHeight: CGFloat = 280
    private static let estimatedEntryCardHeight: CGFloat = 122

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            historyHeaderRow
                .padding(.horizontal, 16)
                .padding(.top, 12)

            localStorageNotice
                .padding(.horizontal, 16)
                .padding(.top, 8)

            historySettingsSection
                .padding(.horizontal, 16)
                .padding(.top, 12)

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            if !dictationHistoryStore.isHistoryEnabled {
                historyDisabledState
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
            } else if dictationHistoryStore.entries.isEmpty {
                historyEmptyState
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
            } else {
                entriesList

                Divider()
                    .background(DS.Colors.borderSubtle)
                    .padding(.horizontal, 16)

                historyFooter
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .onAppear {
            // Enforce retention right when the user looks, in case entries
            // aged out since the last periodic cleanup.
            dictationHistoryStore.removeExpiredEntries()
        }
        .onChange(of: dictationHistoryStore.entries.isEmpty) { _, _ in
            isConfirmingClearAll = false
        }
    }

    // MARK: - Header

    private var historyHeaderRow: some View {
        HStack(spacing: 8) {
            Button(action: onBackButtonPressed) {
                Image(systemName: "chevron.left")
            }
            .dsIconButtonStyle(size: 22, tooltip: "Back", tooltipAlignment: .leading)

            Text("Dictation History")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            Spacer()
        }
    }

    private var localStorageNotice: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.top, 1)

            Text("This history is stored only on this Mac. It's never uploaded, synced, or backed up.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Settings

    private var historySettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Save history")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text("Turning this off deletes saved history.")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { dictationHistoryStore.isHistoryEnabled },
                    set: { dictationHistoryStore.setHistoryEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(DS.Colors.accent)
                .controlSize(.mini)
                .pointerCursor()
            }

            if dictationHistoryStore.isHistoryEnabled {
                HStack {
                    Text("Keep for")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Spacer()

                    segmentedOptionPicker(
                        options: DictationHistoryRetentionPeriod.allCases,
                        selectedOption: dictationHistoryStore.retentionPeriod,
                        labelForOption: { retentionPeriod in retentionPeriod.displayName },
                        onSelectOption: { retentionPeriod in dictationHistoryStore.setRetentionPeriod(retentionPeriod) }
                    )
                }

                HStack {
                    Text("Keep up to")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(DS.Colors.textSecondary)

                    Spacer()

                    segmentedOptionPicker(
                        options: DictationHistoryRetentionPolicy.maximumEntryCountOptions,
                        selectedOption: dictationHistoryStore.maximumEntryCount,
                        labelForOption: { maximumEntryCount in "\(maximumEntryCount)" },
                        onSelectOption: { maximumEntryCount in dictationHistoryStore.setMaximumEntryCount(maximumEntryCount) }
                    )
                }
            }
        }
    }

    /// Compact segmented control matching the Sonnet/Opus model picker in the main panel.
    private func segmentedOptionPicker<Option: Hashable>(
        options: [Option],
        selectedOption: Option,
        labelForOption: @escaping (Option) -> String,
        onSelectOption: @escaping (Option) -> Void
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selectedOption
                Button(action: {
                    onSelectOption(option)
                }) {
                    Text(labelForOption(option))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(isSelected ? Color.white.opacity(0.1) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
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

    // MARK: - Empty / Disabled States

    private var historyDisabledState: some View {
        Text("History is off. Turn it on to keep a local copy of what you say to Clicky, so nothing is lost if a message doesn't go through.")
            .font(.system(size: 11))
            .foregroundColor(DS.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var historyEmptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nothing here yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)

            Text("Hold Control+Option and talk. Your recent messages show up here in case you need them again.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Entries

    /// The list gets an explicit height (instead of letting the ScrollView size
    /// itself) so the menu bar panel can measure its content and fit snugly.
    private var entriesListHeight: CGFloat {
        let estimatedContentHeight = CGFloat(dictationHistoryStore.entries.count) * Self.estimatedEntryCardHeight + 24
        return min(Self.maximumEntriesListHeight, estimatedContentHeight)
    }

    private var entriesList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 8) {
                ForEach(dictationHistoryStore.entries) { dictationHistoryEntry in
                    entryCard(for: dictationHistoryEntry)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(height: entriesListHeight)
    }

    private func entryCard(for dictationHistoryEntry: DictationHistoryEntry) -> some View {
        let entryNeedsAttention = dictationHistoryEntry.status == .failed
            || dictationHistoryEntry.status == .interrupted

        return VStack(alignment: .leading, spacing: 8) {
            Text(dictationHistoryEntry.text)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                entryStatusBadge(for: dictationHistoryEntry.status)

                Spacer()

                Text(dictationHistoryEntry.createdAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            if entryNeedsAttention, let failureReason = dictationHistoryEntry.failureReason {
                Text(failureReason)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                entryActionButton(
                    title: recentlyCopiedEntryID == dictationHistoryEntry.id ? "Copied" : "Copy",
                    systemImageName: recentlyCopiedEntryID == dictationHistoryEntry.id ? "checkmark" : "doc.on.doc",
                    isEnabled: true
                ) {
                    copyEntryText(dictationHistoryEntry)
                }

                entryActionButton(
                    title: "Insert",
                    systemImageName: "text.insert",
                    isEnabled: true
                ) {
                    insertEntryText(dictationHistoryEntry)
                }

                entryActionButton(
                    title: "Ask again",
                    systemImageName: "arrow.clockwise",
                    isEnabled: dictationHistoryEntry.status != .sending
                ) {
                    companionManager.resendDictationHistoryEntryToClaude(dictationHistoryEntry)
                }

                Spacer()

                Button(action: {
                    dictationHistoryStore.deleteEntry(id: dictationHistoryEntry.id)
                }) {
                    Image(systemName: "trash")
                }
                .dsIconButtonStyle(size: 22, isDestructiveOnHover: true, tooltip: "Delete", tooltipAlignment: .trailing)
            }

            if entryIDCopiedBecauseInsertWasUnavailable == dictationHistoryEntry.id {
                Text("Copied instead. Press ⌘V to paste — Clicky needs Accessibility permission to insert text for you.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(entryNeedsAttention ? DS.Colors.warning.opacity(0.35) : DS.Colors.borderSubtle, lineWidth: 0.5)
        )
    }

    private func entryStatusBadge(for entryStatus: DictationHistoryEntryStatus) -> some View {
        let badgeLabel: String
        let badgeColor: Color

        switch entryStatus {
        case .sending:
            badgeLabel = "Sending…"
            badgeColor = DS.Colors.blue400
        case .sent:
            badgeLabel = "Sent"
            badgeColor = DS.Colors.success
        case .failed:
            badgeLabel = "Didn't go through"
            badgeColor = DS.Colors.warningText
        case .interrupted:
            badgeLabel = "Interrupted"
            badgeColor = DS.Colors.warningText
        }

        return HStack(spacing: 4) {
            Circle()
                .fill(badgeColor)
                .frame(width: 6, height: 6)
            Text(badgeLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(badgeColor)
        }
    }

    private func entryActionButton(
        title: String,
        systemImageName: String,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImageName)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .buttonStyle(DictationHistoryEntryActionButtonStyle())
        .disabled(!isEnabled)
        .pointerCursor(isEnabled: isEnabled)
    }

    // MARK: - Footer

    private var historyFooter: some View {
        HStack {
            Text(dictationHistoryStore.entries.count == 1 ? "1 message saved" : "\(dictationHistoryStore.entries.count) messages saved")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)

            Spacer()

            if isConfirmingClearAll {
                Button(action: {
                    isConfirmingClearAll = false
                }) {
                    Text("Cancel")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(DictationHistoryEntryActionButtonStyle())
                .pointerCursor()

                Button(action: {
                    dictationHistoryStore.deleteAllEntries()
                    isConfirmingClearAll = false
                }) {
                    Text("Delete all")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(DictationHistoryEntryActionButtonStyle(isDestructive: true))
                .pointerCursor()
            } else {
                Button(action: {
                    isConfirmingClearAll = true
                }) {
                    Text("Clear all")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(DictationHistoryEntryActionButtonStyle())
                .pointerCursor()
            }
        }
    }

    // MARK: - Actions

    private func copyEntryText(_ dictationHistoryEntry: DictationHistoryEntry) {
        companionManager.copyDictationHistoryEntryToClipboard(dictationHistoryEntry)
        recentlyCopiedEntryID = dictationHistoryEntry.id

        let copiedEntryID = dictationHistoryEntry.id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            // Only reset if the user hasn't copied a different entry since.
            if recentlyCopiedEntryID == copiedEntryID {
                recentlyCopiedEntryID = nil
            }
        }
    }

    private func insertEntryText(_ dictationHistoryEntry: DictationHistoryEntry) {
        let didStartInserting = companionManager.insertDictationHistoryEntryIntoFrontmostApp(dictationHistoryEntry)
        entryIDCopiedBecauseInsertWasUnavailable = didStartInserting ? nil : dictationHistoryEntry.id
    }
}

// MARK: - Action Button Style

/// Small capsule button used for per-entry actions. Brightens on hover so it
/// reads as clickable, and dims when disabled.
private struct DictationHistoryEntryActionButtonStyle: ButtonStyle {
    var isDestructive: Bool = false

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(labelColor(isPressed: configuration.isPressed))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Capsule()
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
            .opacity(isEnabled ? 1.0 : 0.4)
            .contentShape(Capsule())
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }

    private func labelColor(isPressed: Bool) -> Color {
        if isDestructive {
            return (isHovered || isPressed) && isEnabled ? .white : DS.Colors.destructiveText
        }
        return (isHovered || isPressed) && isEnabled ? DS.Colors.textPrimary : DS.Colors.textSecondary
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        guard isEnabled else { return Color.white.opacity(0.04) }

        if isDestructive {
            if isPressed { return DS.Colors.destructive.opacity(0.40) }
            if isHovered { return DS.Colors.destructive.opacity(0.30) }
            return DS.Colors.destructive.opacity(0.10)
        }

        if isPressed { return Color.white.opacity(0.16) }
        if isHovered { return Color.white.opacity(0.10) }
        return Color.white.opacity(0.06)
    }
}
