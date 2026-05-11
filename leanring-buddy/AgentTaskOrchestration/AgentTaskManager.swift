//
//  AgentTaskManager.swift
//  leanring-buddy
//
//  Owns the lifecycle of background agent tasks. Single concurrent task in
//  v1 — further requests get rejected via the announcement callback so the
//  caller can speak them aloud. See docs/agent-tasks-design.md.
//

import AppKit
import Combine
import Foundation
import SwiftUI

/// Decisions the manager can ask the host (CompanionManager) to surface to
/// the user. Wrapped as a callback so the manager itself stays UI-free.
enum AgentTaskAnnouncement {
    case acceptedTask(brief: AgentTaskBrief)
    case rejectedBecauseTaskAlreadyRunning(rejectedBrief: AgentTaskBrief, runningBrief: AgentTaskBrief)
    case rejectedBecauseWorkerNotInstalled(workerInstallInstruction: String)
    case taskCompleted(brief: AgentTaskBrief, finalSummary: String)
    case taskFailed(brief: AgentTaskBrief, failureReason: String)
    case taskCancelled(brief: AgentTaskBrief)
    case followUpDelivered(brief: AgentTaskBrief)
    case followUpRejectedBecauseNoActiveTask
}

@MainActor
final class AgentTaskManager: ObservableObject {

    /// The currently running task, if any. Set as soon as the worker spawns
    /// and cleared once a terminal event arrives.
    @Published private(set) var currentTask: AgentTask?

    /// Tasks that have reached a terminal state. Capped at a small ring so
    /// the panel can show recent completions without unbounded memory growth.
    @Published private(set) var recentlyFinishedTasks: [AgentTask] = []

    /// Set to true when at least one task has been created during this app
    /// session. The panel uses this to decide whether to auto-show itself.
    @Published private(set) var hasEverStartedATask: Bool = false

    /// Host-supplied callback for user-facing announcements. CompanionManager
    /// wires this into its TTS pipeline.
    var announcementHandler: ((AgentTaskAnnouncement) -> Void)?

    private static let maxRecentlyFinishedTaskCount: Int = 5

    private var activeWorker: ClaudeCodeAdapter?
    private var workerEventConsumerTask: Task<Void, Never>?
    private var wallClockBudgetWatchdogTask: Task<Void, Never>?

    // MARK: - Public lifecycle

    /// Attempts to start the brief as a background task. If another task is
    /// already running, the request is rejected and the caller is told via
    /// the announcement handler so it can speak the rejection.
    func startTask(brief: AgentTaskBrief) async {
        DotDebugLogger.log("agent.task", "startTask invoked", metadata: [
            "title": brief.oneLineTitle,
            "workingDir": brief.workingDirectoryURL.path
        ])

        if let runningTask = currentTask, !runningTask.status.isTerminal {
            DotDebugLogger.log("agent.task", "rejected: already running", metadata: [
                "runningTitle": runningTask.brief.oneLineTitle
            ])
            announcementHandler?(.rejectedBecauseTaskAlreadyRunning(
                rejectedBrief: brief,
                runningBrief: runningTask.brief
            ))
            return
        }

        let isWorkerInstalled = await ClaudeCodeAdapter.isInstalledOnSystem()
        DotDebugLogger.log("agent.task", "worker install check", metadata: [
            "isInstalled": isWorkerInstalled
        ])
        guard isWorkerInstalled else {
            announcementHandler?(.rejectedBecauseWorkerNotInstalled(
                workerInstallInstruction: ClaudeCodeAdapter.installInstructionMessage()
            ))
            return
        }

        let newTask = AgentTask(brief: brief, initialStatus: .planning)
        currentTask = newTask
        hasEverStartedATask = true
        announcementHandler?(.acceptedTask(brief: brief))
        DotDebugLogger.log("agent.task", "task accepted and set as current", metadata: [
            "title": brief.oneLineTitle
        ])

        let adapter = ClaudeCodeAdapter()
        activeWorker = adapter

        do {
            DotDebugLogger.log("agent.task", "about to spawn worker")
            let eventStream = try await adapter.spawn(brief: brief)
            newTask.status = .running
            DotDebugLogger.log("agent.task", "spawn returned, status set to running")
            startWallClockBudgetWatchdog(for: newTask)
            consumeEventStream(eventStream, for: newTask)
        } catch {
            newTask.status = .failed
            let failureReason = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            DotDebugLogger.log("agent.task", "spawn threw", metadata: [
                "error": failureReason
            ])
            newTask.events.append(TimestampedAgentTaskEvent(
                event: .errorRaised(text: failureReason)
            ))
            newTask.events.append(TimestampedAgentTaskEvent(
                event: .workerFailed(failureReason: failureReason)
            ))
            newTask.finishedAt = Date()
            announcementHandler?(.taskFailed(brief: brief, failureReason: failureReason))
            archiveFinishedTask(newTask)
            currentTask = nil
            activeWorker = nil
        }
    }

    /// Routes a user-spoken follow-up message to the currently running task.
    /// If no task is running, the caller is told via the announcement handler
    /// so it can fall through to the inline voice-response path instead.
    func sendFollowUpToCurrentTask(_ message: String) async {
        guard let runningTask = currentTask,
              !runningTask.status.isTerminal,
              let adapter = activeWorker else {
            announcementHandler?(.followUpRejectedBecauseNoActiveTask)
            return
        }

        do {
            try await adapter.sendFollowUpMessage(message)
            runningTask.events.append(TimestampedAgentTaskEvent(
                event: .assistantMessage(text: "(user added: \(message))")
            ))
            announcementHandler?(.followUpDelivered(brief: runningTask.brief))
        } catch {
            let errorText = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            runningTask.events.append(TimestampedAgentTaskEvent(
                event: .errorRaised(text: "failed to deliver follow-up: \(errorText)")
            ))
        }
    }

    func cancelCurrentTask() async {
        guard let runningTask = currentTask,
              !runningTask.status.isTerminal,
              let adapter = activeWorker else {
            return
        }
        await adapter.cancel()
        // The adapter's termination handler will yield .workerCancelled and
        // finalize the stream; the consumer task closes out the task object
        // and the announcement. No additional work needed here.
        _ = runningTask
    }

    func revealTaskWorkingDirectoryInFinder(_ task: AgentTask) {
        NSWorkspace.shared.open(task.brief.workingDirectoryURL)
    }

    // MARK: - Stream consumption

    private func consumeEventStream(
        _ eventStream: AsyncThrowingStream<AgentTaskEvent, Error>,
        for task: AgentTask
    ) {
        workerEventConsumerTask?.cancel()
        workerEventConsumerTask = Task { @MainActor [weak self] in
            do {
                for try await event in eventStream {
                    guard let self else { return }
                    self.handleIncomingEvent(event, for: task)
                }
            } catch {
                guard let self else { return }
                let errorText = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                task.events.append(TimestampedAgentTaskEvent(
                    event: .errorRaised(text: errorText)
                ))
                task.status = .failed
                task.finishedAt = Date()
                self.announcementHandler?(.taskFailed(
                    brief: task.brief,
                    failureReason: errorText
                ))
                self.archiveFinishedTask(task)
                self.currentTask = nil
                self.activeWorker = nil
            }
            // Stream ended cleanly. Final state was set by the terminal-event
            // handler in handleIncomingEvent; just clear references.
            self?.wallClockBudgetWatchdogTask?.cancel()
            self?.wallClockBudgetWatchdogTask = nil
        }
    }

    private func handleIncomingEvent(_ event: AgentTaskEvent, for task: AgentTask) {
        task.events.append(TimestampedAgentTaskEvent(event: event))
        DotDebugLogger.log("agent.task", "event received", metadata: [
            "event": String(describing: event).prefix(120).description
        ])

        switch event {
        case .workerCompleted(let finalSummary):
            task.status = .completed
            task.finishedAt = Date()
            announcementHandler?(.taskCompleted(brief: task.brief, finalSummary: finalSummary))
            archiveFinishedTask(task)
            currentTask = nil
            activeWorker = nil
            wallClockBudgetWatchdogTask?.cancel()
            wallClockBudgetWatchdogTask = nil

        case .workerFailed(let failureReason):
            task.status = .failed
            task.finishedAt = Date()
            announcementHandler?(.taskFailed(brief: task.brief, failureReason: failureReason))
            archiveFinishedTask(task)
            currentTask = nil
            activeWorker = nil
            wallClockBudgetWatchdogTask?.cancel()
            wallClockBudgetWatchdogTask = nil

        case .workerCancelled:
            task.status = .cancelled
            task.finishedAt = Date()
            announcementHandler?(.taskCancelled(brief: task.brief))
            archiveFinishedTask(task)
            currentTask = nil
            activeWorker = nil
            wallClockBudgetWatchdogTask?.cancel()
            wallClockBudgetWatchdogTask = nil

        default:
            // Non-terminal — keep going.
            break
        }
    }

    // MARK: - Budget watchdog

    private func startWallClockBudgetWatchdog(for task: AgentTask) {
        wallClockBudgetWatchdogTask?.cancel()
        let timeoutSeconds = task.brief.maxWallClockSeconds
        wallClockBudgetWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard let currentlyRunningTask = self.currentTask,
                  currentlyRunningTask.id == task.id,
                  !currentlyRunningTask.status.isTerminal else {
                return
            }
            currentlyRunningTask.events.append(TimestampedAgentTaskEvent(
                event: .warningEmitted(text: "wall-clock budget exceeded, cancelling task")
            ))
            await self.cancelCurrentTask()
        }
    }

    // MARK: - Archive

    private func archiveFinishedTask(_ task: AgentTask) {
        recentlyFinishedTasks.insert(task, at: 0)
        if recentlyFinishedTasks.count > Self.maxRecentlyFinishedTaskCount {
            recentlyFinishedTasks.removeLast(
                recentlyFinishedTasks.count - Self.maxRecentlyFinishedTaskCount
            )
        }
    }

    // MARK: - Working directory utility

    /// Auto-names a per-task working directory under ~/Desktop/Dot Tasks/.
    /// Slug derived from the title; date appended so distinct tasks with the
    /// same title get distinct dirs. Creates the directory if missing.
    ///
    /// Marked `nonisolated` because it touches only FileManager + pure
    /// string helpers — callers (e.g. AgentTaskPlanner) often run in non-
    /// MainActor contexts and need a sync URL back.
    nonisolated static func makeWorkingDirectoryURL(forTitle title: String) -> URL {
        let baseTasksDirectoryURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent("Dot Tasks")
        try? FileManager.default.createDirectory(
            at: baseTasksDirectoryURL,
            withIntermediateDirectories: true
        )
        let titleSlug = slugify(title)
        let dateString = dateSlug()
        let taskFolderName = titleSlug.isEmpty
            ? "task-\(dateString)"
            : "\(titleSlug)-\(dateString)"
        return baseTasksDirectoryURL.appendingPathComponent(taskFolderName)
    }

    nonisolated private static func slugify(_ source: String) -> String {
        let lowered = source.lowercased()
        var slug = ""
        var lastWasDash = false
        for character in lowered {
            if character.isLetter || character.isNumber {
                slug.append(character)
                lastWasDash = false
            } else if !lastWasDash && !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
        }
        if slug.hasSuffix("-") {
            slug.removeLast()
        }
        return String(slug.prefix(48))
    }

    nonisolated private static func dateSlug() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd-HHmm"
        return dateFormatter.string(from: Date())
    }
}
