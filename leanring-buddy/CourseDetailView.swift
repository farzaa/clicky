import AppKit
import SwiftUI

struct CourseDetailView: View {
    @Environment(DebilFrontendStore.self) private var frontendStore

    let courseId: String
    var onBack: () -> Void

    @State private var searchText = ""

    private var isSearchTextBlank: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var displayedEntries: [DebilWorkspaceEntry] {
        let normalizedQuery = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedQuery.isEmpty else {
            return frontendStore.currentEntries
        }
        return frontendStore.currentEntries.filter {
            $0.entryName.lowercased().contains(normalizedQuery)
        }
    }

    private var selectedWorkspaceName: String {
        frontendStore.selectedWorkspace?.displayName ?? "Course Workspace"
    }

    var body: some View {
        VStack(spacing: 0) {
            DebilHeaderBar(onBrandTap: onBack, brandAccessibilityLabel: "Back to courses")

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    topSection
                    searchField
                    feedbackSection
                    entriesSection
                    previewSection
                }
                .padding(12)
                .frame(maxWidth: .infinity)
            }
        }
        .background(DS.background)
        .task {
            await loadWorkspaceIfNeeded()
        }
    }

    private var topSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(selectedWorkspaceName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DS.foreground)

            HStack(spacing: 8) {
                Text(frontendStore.currentDirectoryPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DS.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                if frontendStore.currentDirectoryPath != "/" {
                    Button("Up") {
                        Task { await frontendStore.navigateToParentDirectory() }
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 11, weight: .medium))
                }

                Button {
                    Task { await frontendStore.loadEntries(at: frontendStore.currentDirectoryPath) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .font(.system(size: 11, weight: .medium))

                Button("Upload files") {
                    openUploadPanel()
                }
                .buttonStyle(.borderedProminent)
                .tint(DS.foreground)
                .foregroundStyle(DS.background)
                .font(.system(size: 11, weight: .semibold))
                .disabled(frontendStore.isUploadingFiles)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(DS.mutedForeground.opacity(0.6))
            TextField("Search files and folders...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(8)
        .background(DS.card.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DS.border.opacity(0.6)))
    }

    @ViewBuilder
    private var feedbackSection: some View {
        if frontendStore.isLoadingEntries {
            ProgressView("Loading entries...")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DS.mutedForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if frontendStore.isUploadingFiles {
            ProgressView("Uploading files...")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DS.mutedForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let workspaceErrorMessage = frontendStore.workspaceErrorMessage, !workspaceErrorMessage.isEmpty {
            Text(workspaceErrorMessage)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DS.destructive)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let statusMessage = frontendStore.statusMessage, !statusMessage.isEmpty {
            Text(statusMessage)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DS.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var entriesSection: some View {
        if displayedEntries.isEmpty {
            Text(
                isSearchTextBlank
                    ? "No entries in this directory yet."
                    : "No entries match \"\(searchText)\"."
            )
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(DS.mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(DS.card.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(DS.border.opacity(0.6))
                    )
            )
        } else {
            VStack(spacing: 8) {
                ForEach(displayedEntries) { workspaceEntry in
                    entryRow(workspaceEntry)
                }
            }
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        if let selectedFilePath = frontendStore.selectedFilePath,
           let selectedFilePreviewText = frontendStore.selectedFilePreviewText {
            VStack(alignment: .leading, spacing: 8) {
                Text("Preview")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.foreground)

                Text(selectedFilePath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DS.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.middle)

                ScrollView {
                    Text(selectedFilePreviewText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DS.foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(minHeight: 140, maxHeight: 220)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(DS.background.opacity(0.6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(DS.border.opacity(0.6))
                        )
                )
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(DS.card.opacity(0.45))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(DS.border.opacity(0.55))
                    )
            )
        }
    }

    private func entryRow(_ workspaceEntry: DebilWorkspaceEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: workspaceEntry.isDirectory ? "folder.fill" : "doc.text")
                .font(.system(size: 13))
                .foregroundStyle(DS.mutedForeground)

            VStack(alignment: .leading, spacing: 2) {
                Text(workspaceEntry.entryName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Text(workspaceEntry.entryType.capitalized)
                    if let sizeBytes = workspaceEntry.sizeBytes {
                        Text("\(sizeBytes) bytes")
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DS.mutedForeground)
            }

            Spacer(minLength: 8)

            if workspaceEntry.isDirectory {
                Button("Open") {
                    Task { await frontendStore.openDirectory(workspaceEntry) }
                }
                .buttonStyle(.bordered)
                .font(.system(size: 11, weight: .medium))
            } else {
                Button("Preview") {
                    Task { await frontendStore.readFile(workspaceEntry) }
                }
                .buttonStyle(.bordered)
                .font(.system(size: 11, weight: .medium))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(DS.card.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(DS.border.opacity(0.55))
                )
        )
    }

    private func openUploadPanel() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = true
        openPanel.treatsFilePackagesAsDirectories = false
        openPanel.prompt = "Upload"

        openPanel.begin { response in
            guard response == .OK else { return }
            let selectedFileURLs = openPanel.urls
            Task { @MainActor in
                await frontendStore.uploadFiles(selectedFileURLs)
            }
        }
    }

    private func loadWorkspaceIfNeeded() async {
        if frontendStore.selectedWorkspaceID != courseId {
            await frontendStore.selectWorkspace(withID: courseId)
            return
        }

        if frontendStore.currentEntries.isEmpty {
            await frontendStore.loadEntries(at: frontendStore.currentDirectoryPath)
        }
    }
}
