//
//  ProjectPickerView.swift
//  yardtalk
//
//  Project picker UI for the menu bar panel: a row with a dropdown menu, a
//  new-project form, and a manage list with inline two-step delete. The
//  three sub-views are switched via the parent's `screen` state because
//  sheets and system alerts misbehave in non-activating NSPanels.
//

import SwiftUI

enum ProjectPickerScreen {
    case main
    case newProject
    case manage
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
    @State private var type: YardTalkProjectType = .presentationPrep
    @State private var errorMessage: String?
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            backRow

            Text("New Project")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)

            nameField
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
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func create() {
        guard canCreate else { return }
        do {
            try store.createProject(name: name, type: type)
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
