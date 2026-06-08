//
//  MemoriesLibraryView.swift
//  leanring-buddy
//
//  Unified memories library with category and status filters, detail view,
//  inline editing, and lifecycle actions.
//

import SwiftUI

enum MemoriesCategoryFilter: String, CaseIterable, Identifiable {
    case all
    case skill
    case preference
    case routine

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .skill: return "Skills"
        case .preference: return "Preferences"
        case .routine: return "Routines"
        }
    }

    var memoryCategory: MemoryCategory? {
        switch self {
        case .all: return nil
        case .skill: return .skill
        case .preference: return .preference
        case .routine: return .routine
        }
    }
}

enum MemoriesStatusFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case stale
    case archived

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .active: return "Active"
        case .stale: return "Stale"
        case .archived: return "Archived"
        }
    }

    var status: TeachingSkillStatus? {
        switch self {
        case .all: return nil
        case .active: return .active
        case .stale: return .stale
        case .archived: return .archived
        }
    }
}

struct MemoriesLibraryView: View {
    @ObservedObject var companionManager: CompanionManager
    let onBack: () -> Void

    @State private var selectedCategoryFilter: MemoriesCategoryFilter = .all
    @State private var selectedStatusFilter: MemoriesStatusFilter = .all
    @State private var selectedMemory: Memory?
    @State private var isEditingSelectedMemory = false
    @State private var memoryEdit = MemoryEdit(
        title: "",
        summary: "",
        body: "",
        bundleIds: [],
        status: .active
    )
    @State private var bundleIdsText = ""

    private var filteredMemories: [Memory] {
        companionManager.memories(
            category: selectedCategoryFilter.memoryCategory,
            status: selectedStatusFilter.status
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            libraryHeader

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            if let selectedMemory {
                memoryDetailView(selectedMemory)
            } else {
                filterPickers
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                memoriesList
            }
        }
    }

    private var libraryHeader: some View {
        HStack(spacing: 8) {
            Button(action: {
                if selectedMemory != nil {
                    cancelEditingIfNeeded()
                    selectedMemory = nil
                } else {
                    onBack()
                }
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Text(selectedMemory?.title ?? "Memories")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var filterPickers: some View {
        VStack(alignment: .leading, spacing: 8) {
            filterRow(
                filters: MemoriesCategoryFilter.allCases,
                selectedFilterID: selectedCategoryFilter.id,
                label: { $0.label },
                onSelect: { filter in
                    selectedCategoryFilter = filter
                },
                accessibilityPrefix: "clicky.panel.memories-library.category"
            )

            filterRow(
                filters: MemoriesStatusFilter.allCases,
                selectedFilterID: selectedStatusFilter.id,
                label: { $0.label },
                onSelect: { filter in
                    selectedStatusFilter = filter
                },
                accessibilityPrefix: "clicky.panel.memories-library.status"
            )
        }
    }

    private func filterRow<Filter: Identifiable>(
        filters: [Filter],
        selectedFilterID: Filter.ID,
        label: @escaping (Filter) -> String,
        onSelect: @escaping (Filter) -> Void,
        accessibilityPrefix: String
    ) -> some View {
        HStack(spacing: 4) {
            ForEach(filters) { filter in
                Button(action: {
                    onSelect(filter)
                }) {
                    Text(label(filter))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(
                            selectedFilterID == filter.id ? DS.Colors.textOnAccent : DS.Colors.textTertiary
                        )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                .fill(selectedFilterID == filter.id ? DS.Colors.accent : Color.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityIdentifier("\(accessibilityPrefix).\(filter.id)")
            }
        }
    }

    private var memoriesList: some View {
        ScrollView {
            if filteredMemories.isEmpty {
                Text(emptyStateMessage)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(filteredMemories) { memory in
                        memoryRow(memory)
                        Divider()
                            .background(DS.Colors.borderSubtle.opacity(0.5))
                            .padding(.leading, 16)
                    }
                }
                .padding(.top, 8)
            }
        }
        .frame(maxHeight: 280)
    }

    private var emptyStateMessage: String {
        switch selectedCategoryFilter {
        case .all:
            return "No memories yet. Teach Clicky something on screen and confirm it worked."
        case .skill:
            return "No skills yet. Teach Clicky something on screen and confirm it worked."
        case .preference:
            return "Preferences will appear here once Clicky learns them."
        case .routine:
            return "Routines will appear here once Clicky learns them."
        }
    }

    private func memoryRow(_ memory: Memory) -> some View {
        HStack(spacing: 8) {
            Button(action: {
                selectedMemory = memory
                isEditingSelectedMemory = false
            }) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(memory.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)
                    }

                    Text("\(memory.category.displayLabel) • \(memory.usageCount) uses • \(memory.status.rawValue)")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button(action: {
                if selectedMemory?.id == memory.id {
                    selectedMemory = nil
                }
                companionManager.deleteMemory(id: memory.id, category: memory.category)
            }) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityIdentifier("clicky.panel.memories-library.row.\(memory.id)")
    }

    @ViewBuilder
    private func memoryDetailView(_ memory: Memory) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if isEditingSelectedMemory {
                    memoryEditForm(memory)
                } else {
                    memoryReadOnlyDetail(memory)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(maxHeight: 320)
    }

    private func memoryReadOnlyDetail(_ memory: Memory) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(memory.summary)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textSecondary)

                Text("\(memory.category.displayLabel) • \(memory.usageCount) uses • \(memory.status.rawValue)")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)

                if !memory.bundleIds.isEmpty {
                    Text(memory.bundleIds.joined(separator: ", "))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }

            HStack(spacing: 8) {
                Button(action: {
                    beginEditing(memory)
                }) {
                    Text("Edit")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.accent)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityIdentifier("clicky.panel.memories-library.edit")

                Spacer()
            }

            Divider()
                .background(DS.Colors.borderSubtle)

            memoryMarkdownBody(memory.body)
        }
    }

    private func memoryEditForm(_ memory: Memory) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            editFieldLabel("Title")
            TextField("Title", text: $memoryEdit.title)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(8)
                .background(editFieldBackground)

            editFieldLabel("Description")
            TextField("Description", text: $memoryEdit.summary)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(8)
                .background(editFieldBackground)

            editFieldLabel("Matched apps (comma-separated bundle IDs)")
            TextField("com.apple.TextEdit, com.apple.dt.Xcode", text: $bundleIdsText)
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(DS.Colors.textSecondary)
                .padding(8)
                .background(editFieldBackground)

            editFieldLabel("Status")
            Picker("Status", selection: $memoryEdit.status) {
                ForEach(TeachingSkillStatus.allCases, id: \.self) { status in
                    Text(status.rawValue.capitalized).tag(status)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            editFieldLabel("Body")
            TextEditor(text: $memoryEdit.body)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(DS.Colors.textSecondary)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 100)
                .padding(8)
                .background(editFieldBackground)

            HStack(spacing: 12) {
                Button(action: {
                    saveEditedMemory(memory)
                }) {
                    Text("Save")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                .fill(DS.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityIdentifier("clicky.panel.memories-library.save")

                Button(action: {
                    cancelEditingIfNeeded()
                }) {
                    Text("Cancel")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
    }

    private var editFieldBackground: some View {
        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle.opacity(0.5), lineWidth: 0.8)
            )
    }

    private func editFieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(DS.Colors.textTertiary)
    }

    private func beginEditing(_ memory: Memory) {
        memoryEdit = MemoryEdit(from: memory)
        bundleIdsText = memory.bundleIds.joined(separator: ", ")
        isEditingSelectedMemory = true
    }

    private func cancelEditingIfNeeded() {
        isEditingSelectedMemory = false
    }

    private func saveEditedMemory(_ memory: Memory) {
        memoryEdit.bundleIds = bundleIdsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        companionManager.updateMemory(id: memory.id, category: memory.category, edit: memoryEdit)
        isEditingSelectedMemory = false

        if let updatedMemory = companionManager.memories.first(where: { $0.id == memory.id }) {
            selectedMemory = updatedMemory
        }
    }

    @ViewBuilder
    private func memoryMarkdownBody(_ body: String) -> some View {
        if let attributedBody = try? AttributedString(
            markdown: body,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributedBody)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        } else {
            Text(body)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

private extension MemoryEdit {
    init(title: String, summary: String, body: String, bundleIds: [String], status: TeachingSkillStatus) {
        self.title = title
        self.summary = summary
        self.body = body
        self.bundleIds = bundleIds
        self.status = status
    }
}
