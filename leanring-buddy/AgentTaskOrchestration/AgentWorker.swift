//
//  AgentWorker.swift
//  leanring-buddy
//
//  Protocol abstracting "an installed coding agent that can execute a
//  background task" so the manager and panel are agnostic to whether the
//  underlying worker is Claude Code, Codex CLI, or anything we ship later.
//

import Foundation

/// One installed coding agent we can spawn. Implementations own the
/// subprocess lifecycle and translate the agent's native event format into
/// `AgentTaskEvent`.
protocol AgentWorker: AnyObject {

    /// Human-readable name shown in the task panel ("Claude Code", "Codex").
    static var workerDisplayName: String { get }

    /// Returns true if the worker is invocable on the user's machine right
    /// now (binary present, auth configured well enough to at least start).
    /// Implementations should be cheap and idempotent.
    static func isInstalledOnSystem() async -> Bool

    /// Short user-facing instruction shown in the panel when the worker is
    /// not installed. Should fit in a single sentence.
    static func installInstructionMessage() -> String

    /// Start the worker against the given brief. Returns a stream of events
    /// that the manager forwards to the task. The stream terminates when
    /// the worker exits — successfully (last event is `.workerCompleted`),
    /// with an error (`.workerFailed`), or after a cancel (`.workerCancelled`).
    func spawn(brief: AgentTaskBrief) async throws -> AsyncThrowingStream<AgentTaskEvent, Error>

    /// Deliver a user-typed-or-spoken follow-up message into the running
    /// worker. Implementations route this through the worker's native
    /// follow-up channel (e.g. Claude Code's stream-json stdin). May throw
    /// if the worker has already exited.
    func sendFollowUpMessage(_ message: String) async throws

    /// Request a graceful stop. Implementations should send a polite signal
    /// first and escalate to SIGKILL after a short grace window. After this
    /// returns, the event stream should yield `.workerCancelled` and end.
    func cancel() async
}
