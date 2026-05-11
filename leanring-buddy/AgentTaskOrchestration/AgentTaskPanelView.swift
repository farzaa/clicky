//
//  AgentTaskPanelView.swift
//  leanring-buddy
//
//  SwiftUI content for the right-edge floating panel that shows the
//  currently running background task and recently finished ones. Hosted by
//  AgentTaskPanelManager inside an NSPanel.
//

import AppKit
import SwiftUI

struct AgentTaskPanelView: View {

    @ObservedObject var agentTaskManager: AgentTaskManager
    var onCloseRequested: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
                .background(DS.Colors.borderSubtle.opacity(0.5))

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    if let runningTask = agentTaskManager.currentTask {
                        AgentTaskCardView(
                            task: runningTask,
                            isCurrentlyRunning: !runningTask.status.isTerminal,
                            onCancelRequested: {
                                Task { await agentTaskManager.cancelCurrentTask() }
                            },
                            onRevealInFinderRequested: {
                                agentTaskManager.revealTaskWorkingDirectoryInFinder(runningTask)
                            }
                        )
                    } else if agentTaskManager.recentlyFinishedTasks.isEmpty {
                        emptyStateSection
                    }

                    if !agentTaskManager.recentlyFinishedTasks.isEmpty {
                        recentlyFinishedSection
                    }
                }
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.lg)
            }
        }
        .frame(width: 380)
        .frame(minHeight: 220, maxHeight: 620)
        .background(DS.Colors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text("Background tasks")
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
            .help("Hide panel")
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md)
    }

    // MARK: - Empty state

    private var emptyStateSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("Nothing running")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            Text("Hold push-to-talk and ask Dot to build, research, or run something substantial — like \"reimplement this paper and give me a demo.\" Dot will hand it off to a coding agent and show progress here.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.md)
        .background(DS.Colors.surface2)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
    }

    // MARK: - Recently finished

    private var recentlyFinishedSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("RECENTLY FINISHED")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.5)
                .foregroundColor(DS.Colors.textTertiary)

            ForEach(agentTaskManager.recentlyFinishedTasks) { finishedTask in
                AgentTaskCompactRowView(
                    task: finishedTask,
                    onRevealInFinderRequested: {
                        agentTaskManager.revealTaskWorkingDirectoryInFinder(finishedTask)
                    }
                )
            }
        }
    }
}

// MARK: - Current task card

private struct AgentTaskCardView: View {

    @ObservedObject var task: AgentTask
    let isCurrentlyRunning: Bool
    let onCancelRequested: () -> Void
    let onRevealInFinderRequested: () -> Void

    @State private var isEventLogExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            cardHeader
            cardSubheader
            if isEventLogExpanded {
                eventLogView
            }
            footerActions
        }
        .padding(DS.Spacing.md)
        .background(DS.Colors.surface2)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(borderColorForStatus, lineWidth: 1)
        )
    }

    private var cardHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
            statusBadge
            Text(task.brief.oneLineTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private var cardSubheader: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isCurrentlyRunning {
                Text("Estimated: \(task.brief.estimatedDurationDescription)")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(action: { isEventLogExpanded.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: isEventLogExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("EVENTS (\(task.events.count))")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.5)
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(task.events.suffix(40))) { timestampedEvent in
                        AgentTaskEventRowView(event: timestampedEvent.event)
                    }
                }
            }
            .frame(maxHeight: 220)
            .padding(DS.Spacing.xs)
            .background(DS.Colors.surface1)
            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
        }
        .padding(.top, DS.Spacing.xs)
    }

    private var footerActions: some View {
        HStack(spacing: DS.Spacing.sm) {
            if isCurrentlyRunning {
                Button(action: onCancelRequested) {
                    Text("Cancel")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(DS.Colors.destructiveText)
                }
                .buttonStyle(.plain)
            }
            Button(action: onRevealInFinderRequested) {
                Text("Reveal in Finder")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.accentText)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.top, DS.Spacing.xs)
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

    private var borderColorForStatus: Color {
        switch task.status {
        case .running, .planning:
            return DS.Colors.accent.opacity(0.4)
        case .failed:
            return DS.Colors.destructive.opacity(0.3)
        default:
            return DS.Colors.borderSubtle
        }
    }
}

// MARK: - Compact finished-task row

private struct AgentTaskCompactRowView: View {
    let task: AgentTask
    let onRevealInFinderRequested: () -> Void

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: iconNameForStatus)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(iconColorForStatus)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.brief.oneLineTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                Text(task.status.rawValue.capitalized)
                    .font(.system(size: 9))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            Spacer()
            Button(action: onRevealInFinderRequested) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Reveal working directory in Finder")
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xs)
        .background(DS.Colors.surface2.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
    }

    private var iconNameForStatus: String {
        switch task.status {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "minus.circle.fill"
        default: return "circle"
        }
    }

    private var iconColorForStatus: Color {
        switch task.status {
        case .completed: return DS.Colors.success
        case .failed: return DS.Colors.destructive
        case .cancelled: return DS.Colors.textTertiary
        default: return DS.Colors.textTertiary
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
