//
//  ProjectPickerView.swift
//  yardtalk
//
//  Project picker UI for the menu bar panel: a row with a dropdown menu, a
//  new-project form, and a manage list with inline two-step delete. The
//  three sub-views are switched via the parent's `screen` state because
//  sheets and system alerts misbehave in non-activating NSPanels.
//

import AppKit
import SwiftUI

enum ProjectPickerScreen {
    case main
    case newProject
    case manage
    case timeline
    case editProject(UUID)
    case settings
    /// Review/edit the structured synthesis output for the given session
    /// before it gets uploaded (M5) or stays local. Reachable from both
    /// the timeline (Summary "Review" button) and the main panel
    /// (tapping the synthesized session's preview blockquote).
    case reviewSession(UUID)
    /// Three-way upload decision dialog (M5). Reached from "Accept &
    /// Continue" in the review screen.
    case uploadDecision(UUID)
    /// Cross-project list of queued/failed uploads (M6).
    case outbox
}

// MARK: - Picker Row

struct ProjectPickerRow: View {
    let store: ProjectStore
    @Binding var screen: ProjectPickerScreen

    var body: some View {
        HStack(spacing: 8) {
            Text("PROJECT")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)

            Menu {
                if !store.projects.isEmpty {
                    ForEach(store.projects) { project in
                        Button {
                            store.setActive(project.id)
                        } label: {
                            if project.id == store.activeProjectID {
                                Label(project.name, systemImage: "checkmark")
                            } else {
                                Text(project.name)
                            }
                        }
                    }
                    Divider()
                }
                Button("New Project…") { screen = .newProject }
                if !store.projects.isEmpty {
                    Button("Manage Projects…") { screen = .manage }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(store.activeProject?.name ?? "Select project")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(store.activeProject == nil
                            ? DS.Colors.textTertiary
                            : DS.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .pointerCursor()

            Spacer()
        }
    }
}

// MARK: - New Project Form

struct NewProjectForm: View {
    let store: ProjectStore
    @Binding var screen: ProjectPickerScreen

    @State private var name: String = ""
    @State private var projectDescription: String = ""
    @State private var type: YardTalkProjectType = .presentationPrep
    @State private var location: URL?
    @State private var errorMessage: String?
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            backRow

            Text("New Project")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            nameField
            descriptionField
            locationPicker
            typePicker

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.9, green: 0.4, blue: 0.4))
            }

            createButton
        }
        .onAppear { nameFieldFocused = true }
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

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NAME")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
            TextField("acme-labs-presentation", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(DS.Colors.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
                .focused($nameFieldFocused)
                .onSubmit { create() }
        }
    }

    private var descriptionField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DESCRIPTION")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
            TextField("What is this project about?", text: $projectDescription, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(3, reservesSpace: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
        }
    }

    private var locationPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LOCATION")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
            Button(action: chooseFolder) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textTertiary)
                    if let location {
                        Text(location.lastPathComponent)
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("Choose folder…")
                            .font(.system(size: 12))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            if let location {
                Text(location.path(percentEncoded: false))
                    .font(.system(size: 9))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select a folder for this project's clips and sessions"
        if panel.runModal() == .OK {
            location = panel.url
        }
    }

    private var typePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TEMPLATE")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(DS.Colors.textTertiary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(YardTalkProjectType.allCases, id: \.self) { option in
                    Button {
                        type = option
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: type == option ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 13))
                                .foregroundColor(type == option ? DS.Colors.accent : DS.Colors.textTertiary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.displayName)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(DS.Colors.textPrimary)
                                Text(option.synthesisDescription)
                                    .font(.system(size: 10))
                                    .foregroundColor(DS.Colors.textTertiary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            }
        }
    }

    private var createButton: some View {
        Button(action: create) {
            Text("Create")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(canCreate ? DS.Colors.accent : DS.Colors.accent.opacity(0.4))
                )
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(!canCreate)
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && location != nil
    }

    private func create() {
        guard canCreate, let location else { return }
        do {
            try store.createProject(name: name, type: type, projectDescription: projectDescription, location: location)
            screen = .main
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Manage Projects

struct ManageProjectsView: View {
    let store: ProjectStore
    @Binding var screen: ProjectPickerScreen
    @State private var pendingDeleteID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            Text("Manage Projects")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            if store.projects.isEmpty {
                Text("No projects yet.")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(store.projects) { project in
                        projectRow(project)
                    }
                }
            }
        }
    }

    private func projectRow(_ project: YardTalkProject) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(project.type.displayName)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
                if !project.projectDescription.isEmpty {
                    Text(project.projectDescription)
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(2)
                }
            }
            Spacer()

            if pendingDeleteID == project.id {
                HStack(spacing: 6) {
                    Button("Cancel") { pendingDeleteID = nil }
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                        .buttonStyle(.plain)
                        .pointerCursor()

                    Button("Delete") {
                        try? store.delete(id: project.id)
                        pendingDeleteID = nil
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color(red: 0.85, green: 0.3, blue: 0.3)))
                    .buttonStyle(.plain)
                    .pointerCursor()
                }
            } else {
                Button {
                    pendingDeleteID = project.id
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }
}

// MARK: - Edit Project

struct EditProjectView: View {
    let store: ProjectStore
    let projectID: UUID
    let onRelocate: (_ projectID: UUID, _ newLocation: URL, _ moveFiles: Bool) throws -> Void
    @Binding var screen: ProjectPickerScreen

    @State private var name: String = ""
    @State private var projectDescription: String = ""
    @State private var errorMessage: String?
    @State private var pendingNewLocation: URL?
    @State private var isRelocating: Bool = false

    private var project: YardTalkProject? {
        store.projects.first(where: { $0.id == projectID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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

            Text("Edit Project")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            VStack(alignment: .leading, spacing: 6) {
                Text("NAME")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.textTertiary)
                TextField("Project name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("DESCRIPTION")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.textTertiary)
                TextField("What is this project about?", text: $projectDescription, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(3, reservesSpace: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
            }

            if let project {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TEMPLATE")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(DS.Colors.textTertiary)
                    Text(project.type.displayName)
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)

                    locationSection(project)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.9, green: 0.4, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: save) {
                Text("Save")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(canSave ? DS.Colors.accent : DS.Colors.accent.opacity(0.4))
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(!canSave)
        }
        .onAppear {
            if let project {
                name = project.name
                projectDescription = project.projectDescription
            }
        }
    }

    @ViewBuilder
    private func locationSection(_ project: YardTalkProject) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("LOCATION")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(DS.Colors.textTertiary)
                Text(project.location.path(percentEncoded: false))
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.head)
            }
            Spacer()
            if pendingNewLocation == nil && !isRelocating {
                Button {
                    chooseNewLocation()
                } label: {
                    Text("Change")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.top, 6)

        if let newLoc = pendingNewLocation {
            relocateConfirmation(from: project.location, to: newLoc)
        }

        if isRelocating {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Moving files…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.accent)
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func relocateConfirmation(from oldLocation: URL, to newLocation: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.accent)
                Text("New location:")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Text(newLocation.path(percentEncoded: false))
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(2)
                .truncationMode(.head)

            HStack(spacing: 6) {
                Button {
                    performRelocate(moveFiles: true)
                } label: {
                    Text("Move Files")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textOnAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(DS.Colors.accent))
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Button {
                    performRelocate(moveFiles: false)
                } label: {
                    Text("Update Path Only")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()

                Spacer()

                Button {
                    pendingNewLocation = nil
                } label: {
                    Text("Cancel")
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(DS.Colors.accent.opacity(0.3), lineWidth: 0.5)
        )
        .padding(.top, 4)
    }

    private func chooseNewLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select the new folder for this project's clips and sessions"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingNewLocation = url
        errorMessage = nil
    }

    private func performRelocate(moveFiles: Bool) {
        guard let newLocation = pendingNewLocation else { return }
        isRelocating = true
        errorMessage = nil
        do {
            try onRelocate(projectID, newLocation, moveFiles)
            pendingNewLocation = nil
            isRelocating = false
        } catch {
            errorMessage = "Relocation failed: \(error.localizedDescription)"
            isRelocating = false
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard canSave, var project else { return }
        project.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        project.projectDescription = projectDescription
        project.updatedAt = Date()
        do {
            try store.updateProject(project)
            screen = .main
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
