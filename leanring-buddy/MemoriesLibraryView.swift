//
//  MemoriesLibraryView.swift
//  leanring-buddy
//
//  Unified memories library with detail view, inline editing, and delete.
//

import SwiftUI

struct MemoriesLibraryView: View {
    @ObservedObject var companionManager: CompanionManager
    let initialSelectedMemoryID: String?
    let onBack: () -> Void

    @State private var selectedMemory: Memory?
    @State private var isEditingSelectedMemory = false
    @State private var memoryEdit = MemoryEdit(
        title: "",
        summary: "",
        body: "",
        bundleIds: [],
        status: .active
    )
    @State private var memoryPendingDelete: Memory?

    private var allMemories: [Memory] {
        companionManager.memories
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
                memoriesList
            }
        }
        .onAppear {
            openInitialMemoryIfNeeded()
        }
        .onChange(of: initialSelectedMemoryID) { _, _ in
            openInitialMemoryIfNeeded()
        }
        .onChange(of: companionManager.memories) { _, _ in
            refreshSelectedMemoryIfNeeded()
        }
        .confirmationDialog(
            "Delete this memory?",
            isPresented: Binding(
                get: { memoryPendingDelete != nil },
                set: { isPresented in
                    if !isPresented {
                        memoryPendingDelete = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                confirmDeletePendingMemory()
            }
            Button("Cancel", role: .cancel) {
                memoryPendingDelete = nil
            }
        } message: {
            Text("This can't be undone.")
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

    private var memoriesList: some View {
        ScrollView {
            if allMemories.isEmpty {
                Text("No memories yet. Teach Clicky something on screen and confirm it worked.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(allMemories) { memory in
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

    private func memoryRow(_ memory: Memory) -> some View {
        HStack(spacing: 8) {
            Button(action: {
                selectedMemory = memory
                isEditingSelectedMemory = false
            }) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(memory.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(1)

                    Text(memory.relativeSavedLabel())
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button(action: {
                memoryPendingDelete = memory
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

                Text(memory.relativeSavedLabel())
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            HStack(spacing: 12) {
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

                Button(action: {
                    memoryPendingDelete = memory
                }) {
                    Text("Delete")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.destructive)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityIdentifier("clicky.panel.memories-library.delete")

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

            editFieldLabel("Steps")
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
        isEditingSelectedMemory = true
    }

    private func cancelEditingIfNeeded() {
        isEditingSelectedMemory = false
    }

    private func saveEditedMemory(_ memory: Memory) {
        var edit = memoryEdit
        edit.bundleIds = memory.bundleIds
        edit.status = memory.status

        companionManager.updateMemory(id: memory.id, category: memory.category, edit: edit)
        isEditingSelectedMemory = false

        if let updatedMemory = companionManager.memories.first(where: { $0.id == memory.id }) {
            selectedMemory = updatedMemory
        }
    }

    private func confirmDeletePendingMemory() {
        guard let memory = memoryPendingDelete else { return }

        if selectedMemory?.id == memory.id {
            selectedMemory = nil
            isEditingSelectedMemory = false
        }

        companionManager.deleteMemory(id: memory.id, category: memory.category)
        memoryPendingDelete = nil
    }

    private func openInitialMemoryIfNeeded() {
        guard let initialSelectedMemoryID,
              let memory = companionManager.memories.first(where: { $0.id == initialSelectedMemoryID }) else {
            return
        }

        selectedMemory = memory
        isEditingSelectedMemory = false
    }

    private func refreshSelectedMemoryIfNeeded() {
        guard let selectedMemory,
              let refreshedMemory = companionManager.memories.first(where: { $0.id == selectedMemory.id }) else {
            return
        }

        self.selectedMemory = refreshedMemory
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
