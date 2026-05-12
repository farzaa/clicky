//
//  AgentTaskPanelView.swift
//  leanring-buddy
//
//  SwiftUI content for the right-edge floating panel that shows the selected
//  coding-agent task. The subagent dot overlay owns the task list; this panel
//  owns the detailed output for whichever dot the user clicked.
//

import AppKit
import SwiftUI

struct AgentTaskPanelView: View {

    @ObservedObject var agentTaskManager: AgentTaskManager
    @ObservedObject var panelSelection: AgentTaskPanelSelection
    var onCancelTaskRequested: (AgentTask) -> Void
    var onCloseRequested: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
                .background(DS.Colors.borderSubtle.opacity(0.5))

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    if let selectedTask {
                        AgentTaskCardView(
                            task: selectedTask,
                            isCurrentlyRunning: !selectedTask.status.isTerminal,
                            onCancelRequested: {
                                onCancelTaskRequested(selectedTask)
                            }
                        )
                    } else {
                        emptyStateSection
                    }
                }
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.lg)
            }
        }
        .frame(width: 380)
        .frame(minHeight: 150, maxHeight: 420)
        .background(DS.Colors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    private var selectedTask: AgentTask? {
        guard let selectedTaskID = panelSelection.selectedTaskID else {
            return nil
        }
        return agentTaskManager.visibleTasksForSubagentDots.first { task in
            task.id == selectedTaskID
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text("Coding agent")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Spacer()
            Button(action: onCloseRequested) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Hide panel")
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md)
    }

    // MARK: - Empty state

    private var emptyStateSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("No task selected")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            Text("Click a colored dot on the right edge to inspect that coding agent's output.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.md)
        .background(DS.Colors.surface2)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
    }
}

// MARK: - Current task card

private struct AgentTaskCardView: View {

    @ObservedObject var task: AgentTask
    let isCurrentlyRunning: Bool
    let onCancelRequested: () -> Void

    @State private var isEventLogExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            cardHeader
            cardSubheader
            if !task.events.isEmpty {
                eventLogView
            }
            if isCurrentlyRunning {
                footerActions
            }
        }
    }

    private var cardHeader: some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            statusBadge
                .padding(.top, 5)
            Text(task.brief.oneLineTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private var cardSubheader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(taskStatusText)
                .font(.system(size: 10))
                .foregroundColor(DS.Colors.textTertiary)
            if let latestAssistantText = task.mostRecentAssistantMessageText, isCurrentlyRunning {
                Text(latestAssistantText)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            if !isCurrentlyRunning, let finalSummary = task.finalSummaryIfCompleted {
                Text(finalSummary)
                    .font(.system(size: 11))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    private var eventLogView: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Button(action: { isEventLogExpanded.toggle() }) {
                HStack(spacing: 5) {
                    Image(systemName: isEventLogExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .frame(width: 10)
                    Text("Events (\(task.events.count))")
                        .font(.system(size: 10, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundColor(DS.Colors.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(isEventLogExpanded ? "Hide event history" : "Show event history")

            if isEventLogExpanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(task.events.suffix(40))) { timestampedEvent in
                            AgentTaskEventRowView(event: timestampedEvent.event)
                        }
                    }
                }
                .frame(maxHeight: 180)
                .padding(DS.Spacing.xs)
                .background(DS.Colors.surface2.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
            }
        }
    }

    private var footerActions: some View {
        HStack {
            Button(action: onCancelRequested) {
                Text("Cancel")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.destructiveText)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            Spacer()
        }
    }

    private var statusBadge: some View {
        Circle()
            .fill(badgeFillColorForStatus)
            .frame(width: 8, height: 8)
            .overlay(
                Group {
                    if isCurrentlyRunning {
                        Circle()
                            .stroke(badgeFillColorForStatus.opacity(0.4), lineWidth: 4)
                            .frame(width: 18, height: 18)
                            .blur(radius: 1)
                    }
                }
            )
    }

    private var badgeFillColorForStatus: Color {
        switch task.status {
        case .queued, .planning:
            return DS.Colors.warning
        case .running:
            return DS.Colors.accent
        case .completed:
            return DS.Colors.success
        case .failed:
            return DS.Colors.destructive
        case .cancelled:
            return DS.Colors.textTertiary
        }
    }

    private var taskStatusText: String {
        switch task.status {
        case .queued:
            return "Queued"
        case .planning:
            return "Planning"
        case .running:
            return "Running • \(task.brief.estimatedDurationDescription)"
        case .completed:
            return "Completed"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }
}

// MARK: - Event row

private struct AgentTaskEventRowView: View {
    let event: AgentTaskEvent

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 9))
                .foregroundColor(iconColor)
                .frame(width: 12, alignment: .center)
                .padding(.top, 2)
            Text(displayText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(displayTextColor)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var iconName: String {
        switch event {
        case .workerStarted: return "play.fill"
        case .plannerPhase: return "circle.dotted"
        case .assistantMessage: return "bubble.left"
        case .toolCallInvoked: return "hammer"
        case .fileEdit: return "doc.text"
        case .shellCommand: return "terminal"
        case .warningEmitted: return "exclamationmark.triangle"
        case .errorRaised: return "xmark.octagon"
        case .workerCompleted: return "checkmark.circle.fill"
        case .workerFailed: return "xmark.octagon.fill"
        case .workerCancelled: return "minus.circle.fill"
        }
    }

    private var iconColor: Color {
        switch event {
        case .warningEmitted: return DS.Colors.warning
        case .errorRaised, .workerFailed: return DS.Colors.destructive
        case .workerCompleted: return DS.Colors.success
        case .toolCallInvoked, .fileEdit, .shellCommand: return DS.Colors.accentText
        default: return DS.Colors.textTertiary
        }
    }

    private var displayText: String {
        switch event {
        case .workerStarted(let workerDisplayName):
            return "started \(workerDisplayName)"
        case .plannerPhase(let description):
            return description
        case .assistantMessage(let text):
            return text
        case .toolCallInvoked(let name, let summary):
            return "\(name): \(summary)"
        case .fileEdit(let filePath, _):
            let lastPathComponent = (filePath as NSString).lastPathComponent
            return "edit \(lastPathComponent)"
        case .shellCommand(let command, _):
            return "$ \(command)"
        case .warningEmitted(let text):
            return text
        case .errorRaised(let text):
            return text
        case .workerCompleted(let finalSummary):
            return "completed — \(finalSummary)"
        case .workerFailed(let failureReason):
            return "failed — \(failureReason)"
        case .workerCancelled:
            return "cancelled"
        }
    }

    private var displayTextColor: Color {
        switch event {
        case .errorRaised, .workerFailed: return DS.Colors.destructiveText
        case .warningEmitted: return DS.Colors.warningText
        case .workerCompleted: return DS.Colors.textPrimary
        case .assistantMessage: return DS.Colors.textSecondary
        default: return DS.Colors.textSecondary
        }
    }
}
