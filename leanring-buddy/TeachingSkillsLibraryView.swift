//
//  TeachingSkillsLibraryView.swift
//  leanring-buddy
//
//  Full teaching skills library with status filters, detail view, and lifecycle actions.
//

import SwiftUI

enum TeachingSkillsLibraryFilter: String, CaseIterable, Identifiable {
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

struct TeachingSkillsLibraryView: View {
    @ObservedObject var companionManager: CompanionManager
    let onBack: () -> Void

    @State private var selectedFilter: TeachingSkillsLibraryFilter = .all
    @State private var selectedSkill: TeachingSkill?

    private var filteredSkills: [TeachingSkill] {
        companionManager.teachingSkills(withStatus: selectedFilter.status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            libraryHeader

            Divider()
                .background(DS.Colors.borderSubtle)
                .padding(.horizontal, 16)

            if let selectedSkill {
                skillDetailView(selectedSkill)
            } else {
                filterPicker
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                skillsList
            }
        }
    }

    private var libraryHeader: some View {
        HStack(spacing: 8) {
            Button(action: {
                if selectedSkill != nil {
                    selectedSkill = nil
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

            Text(selectedSkill?.name ?? "Teaching Skills")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var filterPicker: some View {
        HStack(spacing: 4) {
            ForEach(TeachingSkillsLibraryFilter.allCases) { filter in
                Button(action: {
                    selectedFilter = filter
                }) {
                    Text(filter.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(selectedFilter == filter ? DS.Colors.textOnAccent : DS.Colors.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                                .fill(selectedFilter == filter ? DS.Colors.accent : Color.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityIdentifier("clicky.panel.skills-library.filter.\(filter.rawValue)")
            }
        }
    }

    private var skillsList: some View {
        ScrollView {
            if filteredSkills.isEmpty {
                Text("No \(selectedFilter == .all ? "" : selectedFilter.label.lowercased() + " ")skills.")
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(filteredSkills) { skill in
                        skillRow(skill)
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

    private func skillRow(_ skill: TeachingSkill) -> some View {
        HStack(spacing: 8) {
            Button(action: {
                selectedSkill = skill
            }) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(skill.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(DS.Colors.textSecondary)
                            .lineLimit(1)

                        if skill.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundColor(DS.Colors.accent)
                        }
                    }

                    Text("\(skill.usageCount) uses • \(skill.status.rawValue)")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            if skill.status == .archived || skill.status == .stale {
                Button(action: {
                    companionManager.restoreTeachingSkill(id: skill.id)
                }) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }

            Button(action: {
                companionManager.setTeachingSkillPinned(id: skill.id, pinned: !skill.isPinned)
            }) {
                Image(systemName: skill.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(skill.isPinned ? DS.Colors.accent : DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button(action: {
                if selectedSkill?.id == skill.id {
                    selectedSkill = nil
                }
                companionManager.deleteTeachingSkill(id: skill.id)
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
        .accessibilityIdentifier("clicky.panel.skills-library.row.\(skill.id)")
    }

    private func skillDetailView(_ skill: TeachingSkill) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.description)
                        .font(.system(size: 12))
                        .foregroundColor(DS.Colors.textSecondary)

                    Text("\(skill.usageCount) uses • \(skill.status.rawValue)")
                        .font(.system(size: 10))
                        .foregroundColor(DS.Colors.textTertiary)

                    if !skill.bundleIds.isEmpty {
                        Text(skill.bundleIds.joined(separator: ", "))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }

                Divider()
                    .background(DS.Colors.borderSubtle)

                skillMarkdownBody(skill.body)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(maxHeight: 300)
    }

    @ViewBuilder
    private func skillMarkdownBody(_ body: String) -> some View {
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
