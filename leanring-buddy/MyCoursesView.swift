import SwiftUI

struct MyCoursesView: View {
    @EnvironmentObject private var frontendStore: DebilFrontendStore

    var onBack: () -> Void
    var onCourseDetail: (String) -> Void

    @State private var searchText = ""
    @State private var newWorkspaceName = ""

    private var isNewWorkspaceNameBlank: Bool {
        newWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isSearchTextBlank: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var filteredWorkspaces: [DebilWorkspace] {
        let normalizedQuery = searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedQuery.isEmpty else {
            return frontendStore.workspaces
        }
        return frontendStore.workspaces.filter {
            $0.displayName.lowercased().contains(normalizedQuery)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            DebilHeaderBar(onBrandTap: onBack)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    titleBlock
                    createWorkspaceSection
                    searchField
                    feedbackSection
                    workspaceListSection
                }
                .padding(12)
                .frame(maxWidth: .infinity)
            }
        }
        .background(DS.background)
        .task {
            if frontendStore.workspaces.isEmpty {
                await frontendStore.refreshWorkspaces()
            }
        }
    }

    private var titleBlock: some View {
        HStack(alignment: .top, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(DS.accent.opacity(0.5))
                        .frame(width: 34, height: 34)
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 15))
                        .foregroundStyle(DS.mutedForeground)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("My courses")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DS.foreground)
                    Text("Browse workspaces and manage uploaded materials")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DS.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            Button {
                Task { await frontendStore.refreshWorkspaces() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DS.card.opacity(0.9))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(DS.border.opacity(0.9))
                            )
                    )
            }
            .buttonStyle(.plain)
            .help("Refresh workspaces")
        }
    }

    private var createWorkspaceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New workspace")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(DS.mutedForeground)

            HStack(spacing: 8) {
                TextField("Workspace name", text: $newWorkspaceName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(DS.card.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(DS.border.opacity(0.6))
                    )

                Button("Create") {
                    createWorkspace()
                }
                .buttonStyle(.borderedProminent)
                .tint(DS.foreground)
                .foregroundStyle(DS.background)
                .disabled(frontendStore.isLoadingWorkspaces || isNewWorkspaceNameBlank)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(DS.mutedForeground.opacity(0.6))
            TextField("Search workspaces...", text: $searchText)
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
        if frontendStore.isLoadingWorkspaces {
            ProgressView("Loading workspaces...")
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
    private var workspaceListSection: some View {
        if filteredWorkspaces.isEmpty {
            Text(
                isSearchTextBlank
                    ? "No workspaces yet. Create one to start uploading course files."
                    : "No workspaces match \"\(searchText)\"."
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
                ForEach(filteredWorkspaces) { workspace in
                    workspaceRow(workspace)
                }
            }
        }
    }

    private func workspaceRow(_ workspace: DebilWorkspace) -> some View {
        let isSelected = frontendStore.selectedWorkspaceID == workspace.id

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(workspace.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.foreground)

                    HStack(spacing: 6) {
                        Text(workspace.isRunning ? "Running" : "Stopped")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(workspace.isRunning ? DS.success : DS.mutedForeground)

                        Text(workspace.membershipRole.capitalized)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(DS.mutedForeground)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 6) {
                    Button(workspace.isRunning ? "Stop" : "Launch") {
                        Task {
                            await frontendStore.toggleWorkspaceLaunchState(workspaceID: workspace.id)
                        }
                    }
                    .buttonStyle(.bordered)
                    .font(.system(size: 11, weight: .medium))

                Button("Open") {
                    onCourseDetail(workspace.id)
                    Task {
                        await frontendStore.selectWorkspace(withID: workspace.id)
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.foreground)
                    .foregroundStyle(DS.background)
                    .font(.system(size: 11, weight: .semibold))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(DS.card.opacity(0.45))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            isSelected
                                ? DS.foreground.opacity(0.25)
                                : DS.border.opacity(0.55)
                        )
                )
        )
    }

    private func createWorkspace() {
        let candidateWorkspaceName = newWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidateWorkspaceName.isEmpty else { return }

        Task {
            await frontendStore.createWorkspace(displayName: candidateWorkspaceName)
            if frontendStore.workspaceErrorMessage == nil {
                newWorkspaceName = ""
            }
        }
    }
}
