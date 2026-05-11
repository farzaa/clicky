//
//  MemoryInspectorView.swift
//  leanring-buddy
//
//  Trust surface for what Dot remembers. Lives inside the menu bar panel
//  as a collapsible section. Lets the user browse every memory file the
//  model has written, delete individual entries, and wipe everything.
//
//  Design intent: this exists because silent learning without inspection is
//  a known failure mode (Replika, ChatGPT). Without a visible memory list,
//  any confabulated or prompt-injected entry is invisible until it causes
//  a problem.
//

import SwiftUI

struct MemoryInspectorView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var isInspectorSectionExpanded: Bool = false
    @State private var loadedMemoryEntries: [DotMemoryStore.MemoryEntrySummary] = []
    @State private var loadedConversationHistoryCount: Int = 0
    @State private var isShowingForgetEverythingConfirmation: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeaderRow
            if isInspectorSectionExpanded {
                expandedInspectorContent
            }
        }
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
        .onAppear {
            refreshLoadedMemorySnapshot()
        }
        .confirmationDialog(
            "Forget everything Dot has remembered?",
            isPresented: $isShowingForgetEverythingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget everything", role: .destructive) {
                performForgetEverything()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes all stored facts and the running conversation thread. Cannot be undone.")
        }
    }

    // MARK: - Header (always visible)

    private var sectionHeaderRow: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                isInspectorSectionExpanded.toggle()
            }
            if isInspectorSectionExpanded {
                refreshLoadedMemorySnapshot()
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "brain")
                    .font(.system(size: 12, weight: .medium))
                Text("Memory")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(headerSummaryText)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                Image(systemName: isInspectorSectionExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .foregroundColor(DS.Colors.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var headerSummaryText: String {
        let factsCount = loadedMemoryEntries.count
        let threadCount = loadedConversationHistoryCount
        return "\(factsCount) fact\(factsCount == 1 ? "" : "s") · \(threadCount) turn\(threadCount == 1 ? "" : "s")"
    }

    // MARK: - Expanded content

    private var expandedInspectorContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
                .background(DS.Colors.borderSubtle)

            if loadedMemoryEntries.isEmpty {
                Text("Dot hasn't written any facts yet. As you talk, it will save things like which apps you use and how you like to work — you'll see them here.")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(loadedMemoryEntries) { memoryEntry in
                            MemoryEntryRow(
                                memoryEntry: memoryEntry,
                                onDeleteRequested: { performDeleteOfEntry(memoryEntry) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 180)
            }

            Divider()
                .background(DS.Colors.borderSubtle)

            HStack {
                Text("Conversation thread")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                Spacer()
                Text("\(loadedConversationHistoryCount) turn\(loadedConversationHistoryCount == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                Button(action: performForgetConversationThread) {
                    Text("Forget")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .disabled(loadedConversationHistoryCount == 0)
            }

            Button(action: { isShowingForgetEverythingConfirmation = true }) {
                Text("Forget everything")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.red.opacity(0.9))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                            .fill(Color.red.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    // MARK: - Actions

    private func refreshLoadedMemorySnapshot() {
        loadedMemoryEntries = DotMemoryStore.listAllMemoryEntries()
        loadedConversationHistoryCount = companionManager.currentConversationHistoryEntryCount
    }

    private func performDeleteOfEntry(_ memoryEntry: DotMemoryStore.MemoryEntrySummary) {
        DotMemoryStore.deleteEntry(virtualPath: memoryEntry.virtualPath)
        DotDebugLogger.log("memory.tool", "user deleted entry via inspector", metadata: [
            "virtualPath": memoryEntry.virtualPath
        ])
        refreshLoadedMemorySnapshot()
    }

    private func performForgetConversationThread() {
        companionManager.forgetConversationThread()
        refreshLoadedMemorySnapshot()
    }

    private func performForgetEverything() {
        DotMemoryStore.wipeAllMemoriesIncludingPinned()
        companionManager.forgetConversationThread()
        DotDebugLogger.log("memory.tool", "user wiped all memory + thread via inspector")
        refreshLoadedMemorySnapshot()
    }
}

/// One row inside the expanded inspector list. Filename + first-line
/// preview + delete button; pinned entries get a subtle pin glyph so the
/// user can tell at a glance which are user-locked vs auto-extracted.
private struct MemoryEntryRow: View {
    let memoryEntry: DotMemoryStore.MemoryEntrySummary
    let onDeleteRequested: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if memoryEntry.isPinnedEntry {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 12)
            } else {
                Spacer().frame(width: 12)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(memoryEntry.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                Text(memoryEntry.firstNonEmptyLineText)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: onDeleteRequested) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Forget this")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
    }
}
