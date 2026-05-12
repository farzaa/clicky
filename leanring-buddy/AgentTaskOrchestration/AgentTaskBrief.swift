//
//  AgentTaskBrief.swift
//  leanring-buddy
//
//  Core types for the background agent-task pipeline. See
//  docs/agent-tasks-design.md.
//

import Combine
import Foundation

/// The structured request produced from an explicit `dot agent ...` command or
/// deterministic personal-task route and handed to an `AgentWorker` to execute.
/// A brief is immutable once created; mutable lifecycle state lives on
/// `AgentTask`.
struct AgentTaskBrief: Identifiable, Equatable {
    let id: UUID
    let oneLineTitle: String
    let userOriginalRequest: String
    let detailedInstructions: String
    let workingDirectoryURL: URL
    let additionalDirectoryURLs: [URL]
    let originatingSource: String?
    let estimatedDurationDescription: String
    let maxToolCallSteps: Int
    let maxWallClockSeconds: Int

    static let defaultMaxToolCallSteps: Int = 120
    static let defaultMaxWallClockSeconds: Int = 2700
}

/// One unit of progress emitted by a worker. The panel renders these as
/// rows in the event log; the manager also uses them to update task status
/// and to drive the optional completion TTS line.
enum AgentTaskEvent: Equatable {
    case workerStarted(workerDisplayName: String)
    case plannerPhase(description: String)
    case assistantMessage(text: String)
    case toolCallInvoked(name: String, oneLineSummary: String)
    case fileEdit(filePath: String, summaryDiff: String?)
    case shellCommand(command: String, output: String?)
    case warningEmitted(text: String)
    case errorRaised(text: String)
    case workerCompleted(finalSummary: String)
    case workerFailed(failureReason: String)
    case workerCancelled
}

/// Lifecycle status of one task. Used by the panel for badge colors and by
/// the manager for routing follow-up messages to the right place.
enum AgentTaskStatus: String, Equatable {
    case queued
    case planning
    case running
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .queued, .planning, .running:
            return false
        }
    }
}

/// One background task with its brief, status, and the ordered list of
/// events it has emitted. Mutable so the manager can append events as they
/// arrive. Identifies on the brief's UUID.
final class AgentTask: ObservableObject, Identifiable {
    let brief: AgentTaskBrief
    let startedAt: Date

    @Published var status: AgentTaskStatus
    @Published var events: [TimestampedAgentTaskEvent] = []
    @Published var finishedAt: Date?

    var id: UUID { brief.id }

    init(brief: AgentTaskBrief, initialStatus: AgentTaskStatus = .queued) {
        self.brief = brief
        self.startedAt = Date()
        self.status = initialStatus
    }

    /// Convenience: the most recent assistant message text, used in the
    /// panel header so the user can see at a glance what the agent is up to.
    var mostRecentAssistantMessageText: String? {
        for event in events.reversed() {
            if case .assistantMessage(let messageText) = event.event {
                return messageText
            }
        }
        return nil
    }

    /// Convenience: the final summary if the task completed. Used by the
    /// manager's TTS announcement and by the panel's terminal-row display.
    var finalSummaryIfCompleted: String? {
        for event in events.reversed() {
            if case .workerCompleted(let summary) = event.event {
                return summary
            }
        }
        return nil
    }
}

/// An event paired with the wall-clock time it arrived. The timestamp is
/// what lets the panel show "12s ago" relative ages.
struct TimestampedAgentTaskEvent: Identifiable {
    let id: UUID
    let timestamp: Date
    let event: AgentTaskEvent

    init(event: AgentTaskEvent, timestamp: Date = Date()) {
        self.id = UUID()
        self.timestamp = timestamp
        self.event = event
    }
}
