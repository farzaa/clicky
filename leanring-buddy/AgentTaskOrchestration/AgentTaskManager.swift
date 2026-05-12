//
//  AgentTaskManager.swift
//  leanring-buddy
//
//  Owns the lifecycle of background agent tasks. Multiple coding agents can
//  run concurrently; each task owns its worker, event stream, and watchdog.
//  See docs/agent-tasks-design.md.
//

import AppKit
import Combine
import Foundation
import SwiftUI

/// Decisions the manager can ask the host (CompanionManager) to surface to
/// the user. Wrapped as a callback so the manager itself stays UI-free.
enum AgentTaskAnnouncement {
    case acceptedTask(brief: AgentTaskBrief)
    case rejectedBecauseTooManyTasks(rejectedBrief: AgentTaskBrief, maxConcurrentTaskCount: Int)
    case rejectedBecauseWorkerNotInstalled(workerInstallInstruction: String)
    case taskCompleted(brief: AgentTaskBrief, finalSummary: String)
    case taskFailed(brief: AgentTaskBrief, failureReason: String)
    case taskCancelled(brief: AgentTaskBrief)
}

@MainActor
final class AgentTaskManager: ObservableObject {

    /// Coding-agent tasks that have not yet reached a terminal state. Each
    /// running task has a matching worker in `activeWorkersByTaskID`.
    @Published private(set) var runningTasks: [AgentTask] = []

    /// Tasks that have reached a terminal state. Capped at a small ring so
    /// the overlay and panel can show recent completions without unbounded
    /// memory growth.
    @Published private(set) var recentlyFinishedTasks: [AgentTask] = []

    /// Set to true when at least one task has been created during this app
    /// session. The panel uses this to decide whether to auto-show itself.
    @Published private(set) var hasEverStartedATask: Bool = false

    /// Host-supplied callback for user-facing announcements. CompanionManager
    /// wires this into its TTS pipeline.
    var announcementHandler: ((AgentTaskAnnouncement) -> Void)?

    private static let maxRecentlyFinishedTaskCount: Int = 5
    private static let maxConcurrentTaskCount: Int = 5

    private var activeWorkersByTaskID: [UUID: ClaudeCodeAdapter] = [:]
    private var workerEventConsumerTasksByTaskID: [UUID: Task<Void, Never>] = [:]
    private var wallClockBudgetWatchdogTasksByTaskID: [UUID: Task<Void, Never>] = [:]
    private var deletedTaskIDs: Set<UUID> = []

    var hasActiveTask: Bool {
        runningTasks.contains { !$0.status.isTerminal }
    }

    var mostRecentRunningTask: AgentTask? {
        runningTasks.last(where: { !$0.status.isTerminal })
    }

    var visibleTasksForSubagentDots: [AgentTask] {
        runningTasks + recentlyFinishedTasks
    }

    // MARK: - Public lifecycle

    /// Attempts to start the brief as a background task. Coding agents are
    /// safe to parallelize because each one works in its own generated
    /// directory, so new requests spawn new workers until the concurrency cap.
    func startTask(brief: AgentTaskBrief) async {
        DotDebugLogger.log("agent.task", "startTask invoked", metadata: [
            "title": brief.oneLineTitle,
            "workingDir": brief.workingDirectoryURL.path
        ])

        if runningTasks.count >= Self.maxConcurrentTaskCount {
            DotDebugLogger.log("agent.task", "rejected: concurrency cap reached", metadata: [
                "maxConcurrentTaskCount": Self.maxConcurrentTaskCount
            ])
            announcementHandler?(.rejectedBecauseTooManyTasks(
                rejectedBrief: brief,
                maxConcurrentTaskCount: Self.maxConcurrentTaskCount
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
        runningTasks.append(newTask)
        hasEverStartedATask = true
        announcementHandler?(.acceptedTask(brief: brief))
        DotDebugLogger.log("agent.task", "task accepted", metadata: [
            "title": brief.oneLineTitle,
            "runningTaskCount": runningTasks.count
        ])

        let adapter = ClaudeCodeAdapter()
        activeWorkersByTaskID[newTask.id] = adapter

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
            removeRunningTask(withID: newTask.id)
            activeWorkersByTaskID[newTask.id] = nil
        }
    }

    func cancelMostRecentRunningTask() async {
        guard let runningTask = mostRecentRunningTask else {
            return
        }
        await cancelTask(taskID: runningTask.id)
    }

    func cancelTask(taskID: UUID) async {
        guard let runningTask = runningTasks.first(where: { $0.id == taskID }),
              !runningTask.status.isTerminal,
              let adapter = activeWorkersByTaskID[taskID] else {
            return
        }
        await adapter.cancel()
        // The adapter's termination handler will yield .workerCancelled and
        // finalize the stream; the consumer task closes out the task object
        // and the announcement. No additional work needed here.
        _ = runningTask
    }

    /// Removes a subagent from Dot's UI state. If the task is still running,
    /// deleting it also cancels the worker. The working directory stays on
    /// disk so "delete" never destroys generated files or logs.
    func deleteTask(taskID: UUID) async {
        deletedTaskIDs.insert(taskID)

        DotDebugLogger.log("agent.task", "deleteTask invoked", metadata: [
            "taskID": taskID.uuidString
        ])

        workerEventConsumerTasksByTaskID[taskID]?.cancel()
        workerEventConsumerTasksByTaskID[taskID] = nil

        wallClockBudgetWatchdogTasksByTaskID[taskID]?.cancel()
        wallClockBudgetWatchdogTasksByTaskID[taskID] = nil

        let adapter = activeWorkersByTaskID[taskID]
        activeWorkersByTaskID[taskID] = nil

        if let runningTask = runningTasks.first(where: { $0.id == taskID }),
           !runningTask.status.isTerminal {
            runningTask.status = .cancelled
            runningTask.finishedAt = Date()
        }
        removeRunningTask(withID: taskID)
        recentlyFinishedTasks.removeAll { $0.id == taskID }

        if let adapter {
            await adapter.cancel()
        }
    }

    func revealTaskWorkingDirectoryInFinder(_ task: AgentTask) {
        NSWorkspace.shared.open(task.brief.workingDirectoryURL)
    }

    // MARK: - Stream consumption

    private func consumeEventStream(
        _ eventStream: AsyncThrowingStream<AgentTaskEvent, Error>,
        for task: AgentTask
    ) {
        workerEventConsumerTasksByTaskID[task.id]?.cancel()
        workerEventConsumerTasksByTaskID[task.id] = Task { @MainActor [weak self] in
            do {
                for try await event in eventStream {
                    guard let self else { return }
                    if self.deletedTaskIDs.contains(task.id) {
                        return
                    }
                    self.handleIncomingEvent(event, for: task)
                }
            } catch {
                guard let self else { return }
                if self.deletedTaskIDs.contains(task.id) {
                    return
                }
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
                self.removeRunningTask(withID: task.id)
                self.activeWorkersByTaskID[task.id] = nil
            }
            // Stream ended cleanly. Final state was set by the terminal-event
            // handler in handleIncomingEvent. If the worker exited without
            // one, mark the task failed so it never gets stuck as running.
            guard let self else { return }
            if self.deletedTaskIDs.contains(task.id) {
                self.workerEventConsumerTasksByTaskID[task.id] = nil
                self.activeWorkersByTaskID[task.id] = nil
                return
            }
            if !task.status.isTerminal {
                let failureReason = "worker exited without a terminal event"
                task.events.append(TimestampedAgentTaskEvent(
                    event: .errorRaised(text: failureReason)
                ))
                task.status = .failed
                task.finishedAt = Date()
                self.announcementHandler?(.taskFailed(
                    brief: task.brief,
                    failureReason: failureReason
                ))
                self.archiveFinishedTask(task)
                self.removeRunningTask(withID: task.id)
            }
            self.wallClockBudgetWatchdogTasksByTaskID[task.id]?.cancel()
            self.wallClockBudgetWatchdogTasksByTaskID[task.id] = nil
            self.workerEventConsumerTasksByTaskID[task.id] = nil
            self.activeWorkersByTaskID[task.id] = nil
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
            removeRunningTask(withID: task.id)
            activeWorkersByTaskID[task.id] = nil
            wallClockBudgetWatchdogTasksByTaskID[task.id]?.cancel()
            wallClockBudgetWatchdogTasksByTaskID[task.id] = nil

        case .workerFailed(let failureReason):
            task.status = .failed
            task.finishedAt = Date()
            announcementHandler?(.taskFailed(brief: task.brief, failureReason: failureReason))
            archiveFinishedTask(task)
            removeRunningTask(withID: task.id)
            activeWorkersByTaskID[task.id] = nil
            wallClockBudgetWatchdogTasksByTaskID[task.id]?.cancel()
            wallClockBudgetWatchdogTasksByTaskID[task.id] = nil

        case .workerCancelled:
            task.status = .cancelled
            task.finishedAt = Date()
            announcementHandler?(.taskCancelled(brief: task.brief))
            archiveFinishedTask(task)
            removeRunningTask(withID: task.id)
            activeWorkersByTaskID[task.id] = nil
            wallClockBudgetWatchdogTasksByTaskID[task.id]?.cancel()
            wallClockBudgetWatchdogTasksByTaskID[task.id] = nil

        default:
            // Non-terminal — keep going.
            break
        }
    }

    // MARK: - Budget watchdog

    private func startWallClockBudgetWatchdog(for task: AgentTask) {
        wallClockBudgetWatchdogTasksByTaskID[task.id]?.cancel()
        let timeoutSeconds = task.brief.maxWallClockSeconds
        wallClockBudgetWatchdogTasksByTaskID[task.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            guard let currentlyRunningTask = self.runningTasks.first(where: { $0.id == task.id }),
                  !currentlyRunningTask.status.isTerminal else {
                return
            }
            currentlyRunningTask.events.append(TimestampedAgentTaskEvent(
                event: .warningEmitted(text: "wall-clock budget exceeded, cancelling task")
            ))
            await self.cancelTask(taskID: task.id)
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

    private func removeRunningTask(withID taskID: UUID) {
        runningTasks.removeAll { $0.id == taskID }
    }

    // MARK: - Working directory utility

    /// Auto-names a per-task working directory under ~/Desktop/Dot Tasks/.
    /// Slug derived from the title; date appended so distinct tasks with the
    /// same title get distinct dirs. Creates the directory if missing.
    ///
    /// Marked `nonisolated` because it touches only FileManager + pure
    /// string helpers, and routing code may need a sync URL before handing
    /// the task to the MainActor manager.
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
