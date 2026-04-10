//
//  DelegationLogSidebar.swift
//  leanring-buddy
//
//  Streams Codex delegation logs into a right-edge sidebar with a dramatic
//  dark-and-purple terminal aesthetic that matches Clicky's Headout theme.
//
//  Supports multiple concurrent delegation sessions: every launched agent
//  gets its own independent sidebar panel, its own log tail, and its own
//  process-lifecycle watcher. Sessions can be individually closed or
//  minimized to a compact bar that can be clicked to restore.
//

import AppKit
import Combine
import Darwin
import SwiftUI

// MARK: - Non-keying panel

/// A borderless, non-activating panel that also refuses to ever become the
/// key window. The delegation log sidebar purely displays information — it
/// does not handle keyboard input itself — so we prevent it from stealing
/// the key-window state from other apps. This is defensive: it keeps
/// push-to-talk and other global keyboard handling flowing normally even if
/// the user clicks on the sidebar (e.g. to select log text).
private final class NonKeyingBorderlessPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - View model (one per session)

@MainActor
final class DelegationLogSidebarViewModel: ObservableObject {
    @Published var workspaceName: String = ""
    @Published var runtimeDisplayName: String = ""
    @Published var logFilePath: String = ""
    @Published var visibleLogLines: [String] = []
    @Published var statusText: String = "Waiting for logs..."
    @Published var latestLogActivityAt: Date = .distantPast
    @Published var baseBranchName: String = ""
    @Published var workingBranchName: String = ""
    @Published var isProcessComplete: Bool = false
    @Published var comparePullRequestURL: URL?
    @Published var isMinimized: Bool = false
    /// True while the session is sitting in a per-workspace delegation
    /// queue, waiting for a previous delegation in the same workspace
    /// to finish before it can begin. The panel renders a distinct
    /// "queued" presentation during this state and the log tail /
    /// process monitoring timers stay dormant until the session is
    /// promoted to running.
    @Published var isQueuedWaitingForPickup: Bool = false
    /// Count of commits the delegated agent made on the working branch
    /// ahead of the base branch, populated after the process exits. Used
    /// to warn the user when an agent finishes without committing
    /// anything (which would otherwise produce an empty pull request).
    /// -1 means "not yet measured".
    @Published var commitsAheadOfBaseCount: Int = -1

    var joinedLogText: String {
        visibleLogLines.joined(separator: "\n")
    }
}

// MARK: - Claude Code stream-json parser

/// Parses Claude Code's `--output-format stream-json` output into
/// human-readable log lines for the sidebar. Claude Code writes one JSON
/// object per line (JSON Lines) — each object is a frame describing the
/// session, streaming assistant text deltas, tool uses, tool results, or
/// the final result. The parser buffers partial lines across `ingest`
/// calls and accumulates text deltas within a text content block so
/// assistant prose renders as discrete lines instead of tiny fragments.
@MainActor
final class DelegationLogClaudeStreamJSONParser {
    /// Bytes received from the log tail that haven't yet formed a
    /// complete line (no trailing newline yet).
    private var incompleteLineBuffer: String = ""
    /// Assistant text deltas accumulate here within a single text content
    /// block. When a newline appears, everything up to it gets emitted
    /// as one visible line; the remainder stays in the accumulator until
    /// the next delta or the block stops.
    private var assistantTextAccumulator: String = ""
    /// Table of in-flight tool_use blocks indexed by their content block
    /// index so we can match `input_json_delta` frames back to the
    /// matching tool name when we finally emit the invocation line.
    private var activeToolUseBlocksByIndex: [Int: ActiveToolUseBlock] = [:]

    private struct ActiveToolUseBlock {
        let toolName: String
        var partialInputJSONBuffer: String
    }

    func ingest(rawText: String) -> [String] {
        var producedLines: [String] = []

        incompleteLineBuffer += rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        while let newlineIndex = incompleteLineBuffer.firstIndex(of: "\n") {
            let completedRawLine = String(incompleteLineBuffer[..<newlineIndex])
            incompleteLineBuffer.removeSubrange(...newlineIndex)
            let trimmedCompletedLine = completedRawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmedCompletedLine.isEmpty else { continue }
            producedLines.append(contentsOf: parseSingleJSONLine(trimmedCompletedLine))
        }

        return producedLines
    }

    /// Drains whatever is still buffered inside the parser when the
    /// delegated process is known to have exited. This matters because
    /// Claude Code's final line — typically the `result` frame — may be
    /// written without a trailing newline right before the CLI exits.
    /// Without this flush, the sidebar would never see the final
    /// `✓ result · ...` line, and any last dangling assistant text still
    /// sitting in the accumulator would be lost.
    func flushPendingBuffer() -> [String] {
        var producedLines: [String] = []

        let leftoverLine = incompleteLineBuffer.trimmingCharacters(in: .whitespaces)
        incompleteLineBuffer = ""
        if !leftoverLine.isEmpty {
            producedLines.append(contentsOf: parseSingleJSONLine(leftoverLine))
        }

        // Any text still sitting in the accumulator (e.g. the stream ended
        // without a final content_block_stop frame) should become a
        // visible log line too.
        producedLines.append(contentsOf: flushAssistantAccumulator())

        return producedLines
    }

    private func parseSingleJSONLine(_ jsonLine: String) -> [String] {
        // If the line isn't valid JSON for some reason (e.g. stderr noise
        // from a failing runtime), pass it through verbatim so the user
        // still sees the error in the sidebar.
        guard let lineData = jsonLine.data(using: .utf8),
              let parsedJSONObject = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let frameType = parsedJSONObject["type"] as? String else {
            return [jsonLine]
        }

        switch frameType {
        case "system":
            return parseSystemFrame(parsedJSONObject)
        case "stream_event":
            return parseStreamEventFrame(parsedJSONObject)
        case "assistant":
            // Complete assistant message — the text is already streamed
            // through content_block_delta frames above, so emitting this
            // would just duplicate content.
            return []
        case "user":
            return parseUserMessageFrame(parsedJSONObject)
        case "result":
            return parseResultFrame(parsedJSONObject)
        case "rate_limit_event":
            // Not useful to surface; hidden to keep the sidebar clean.
            return []
        default:
            // Unknown frame type — ignore rather than pollute the log.
            return []
        }
    }

    private func parseSystemFrame(_ frameJSON: [String: Any]) -> [String] {
        guard let subtype = frameJSON["subtype"] as? String else { return [] }

        // Hook lifecycle frames are noisy and unhelpful to humans.
        if subtype.hasPrefix("hook_") {
            return []
        }

        if subtype == "init" {
            let model = (frameJSON["model"] as? String) ?? "unknown model"
            let toolNames = (frameJSON["tools"] as? [String]) ?? []
            return [
                "⚙ claude session started",
                "   model: \(model)",
                "   tools: \(toolNames.count) available",
                ""
            ]
        }

        return []
    }

    private func parseStreamEventFrame(_ frameJSON: [String: Any]) -> [String] {
        guard let event = frameJSON["event"] as? [String: Any],
              let eventType = event["type"] as? String else {
            return []
        }

        switch eventType {
        case "content_block_start":
            return handleContentBlockStart(event: event)

        case "content_block_delta":
            return handleContentBlockDelta(event: event)

        case "content_block_stop":
            return handleContentBlockStop(event: event)

        case "message_start", "message_delta", "message_stop":
            return []

        default:
            return []
        }
    }

    private func handleContentBlockStart(event: [String: Any]) -> [String] {
        guard let contentBlock = event["content_block"] as? [String: Any],
              let blockType = contentBlock["type"] as? String else {
            return []
        }

        let blockIndex = event["index"] as? Int ?? -1

        switch blockType {
        case "text":
            // New assistant text block — reset the accumulator so any
            // leftover bytes from a previous block don't bleed in.
            flushAssistantAccumulator()
            assistantTextAccumulator = ""
            return []

        case "tool_use":
            // Start buffering tool input JSON so we can render the full
            // invocation when the block stops. If the block has an
            // `input` field already populated (rare — usually it streams
            // via input_json_delta frames), seed the buffer with it.
            let toolName = (contentBlock["name"] as? String) ?? "tool"
            var seededInputJSONBuffer = ""
            if let seededInput = contentBlock["input"] as? [String: Any],
               !seededInput.isEmpty,
               let seededInputData = try? JSONSerialization.data(withJSONObject: seededInput),
               let seededInputText = String(data: seededInputData, encoding: .utf8) {
                seededInputJSONBuffer = seededInputText
            }
            activeToolUseBlocksByIndex[blockIndex] = ActiveToolUseBlock(
                toolName: toolName,
                partialInputJSONBuffer: seededInputJSONBuffer
            )
            // Flush any pending text before showing the tool invocation
            // so the tool line reads as a clear break from the prose.
            var producedLines: [String] = []
            producedLines.append(contentsOf: flushAssistantAccumulator())
            producedLines.append("")
            producedLines.append("→ \(toolName)")
            return producedLines

        default:
            return []
        }
    }

    private func handleContentBlockDelta(event: [String: Any]) -> [String] {
        guard let delta = event["delta"] as? [String: Any],
              let deltaType = delta["type"] as? String else {
            return []
        }

        let blockIndex = event["index"] as? Int ?? -1

        switch deltaType {
        case "text_delta":
            guard let textFragment = delta["text"] as? String else { return [] }
            assistantTextAccumulator += textFragment
            // Emit any complete lines now; keep any partial tail in the
            // accumulator for the next delta.
            var producedLines: [String] = []
            while let newlineIndex = assistantTextAccumulator.firstIndex(of: "\n") {
                let completedTextLine = String(assistantTextAccumulator[..<newlineIndex])
                assistantTextAccumulator.removeSubrange(...newlineIndex)
                producedLines.append(completedTextLine)
            }
            return producedLines

        case "input_json_delta":
            // Tool input JSON arriving piece by piece. Buffer it; we'll
            // render a one-line preview when the block stops.
            guard let partialJSONFragment = delta["partial_json"] as? String else { return [] }
            if var activeToolUseBlock = activeToolUseBlocksByIndex[blockIndex] {
                activeToolUseBlock.partialInputJSONBuffer += partialJSONFragment
                activeToolUseBlocksByIndex[blockIndex] = activeToolUseBlock
            }
            return []

        default:
            return []
        }
    }

    private func handleContentBlockStop(event: [String: Any]) -> [String] {
        let blockIndex = event["index"] as? Int ?? -1

        // Flush any assistant text remaining in the accumulator.
        var producedLines: [String] = flushAssistantAccumulator()

        // If a tool_use block is ending, render a compact invocation line
        // using the buffered input JSON.
        if let finishedToolUseBlock = activeToolUseBlocksByIndex.removeValue(forKey: blockIndex) {
            let inputPreview = compactToolInputPreview(
                forToolName: finishedToolUseBlock.toolName,
                rawInputJSON: finishedToolUseBlock.partialInputJSONBuffer
            )
            if !inputPreview.isEmpty {
                producedLines.append("   \(inputPreview)")
            }
        }

        return producedLines
    }

    /// Drains the assistant text accumulator. Emits a line for any
    /// buffered text even if it doesn't end with a newline — this is
    /// called at the end of a content block, which is the "commit point"
    /// for the current streaming prose.
    private func flushAssistantAccumulator() -> [String] {
        guard !assistantTextAccumulator.isEmpty else { return [] }
        let flushedText = assistantTextAccumulator
        assistantTextAccumulator = ""
        return [flushedText]
    }

    /// Pulls out the most useful field from a tool's input JSON so the
    /// sidebar can render a one-liner (e.g. `Bash · git status` instead
    /// of the full JSON blob). Falls back to a truncated JSON string for
    /// tools we don't special-case.
    private func compactToolInputPreview(forToolName toolName: String, rawInputJSON: String) -> String {
        let trimmedInputJSON = rawInputJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInputJSON.isEmpty else { return "" }

        if let inputJSONData = trimmedInputJSON.data(using: .utf8),
           let parsedInputObject = try? JSONSerialization.jsonObject(with: inputJSONData) as? [String: Any] {

            // Common single-field previews
            if let commandString = parsedInputObject["command"] as? String {
                return truncatedPreview(forToolName: toolName, bodyText: commandString)
            }
            if let filePath = parsedInputObject["file_path"] as? String {
                return truncatedPreview(forToolName: toolName, bodyText: filePath)
            }
            if let patternText = parsedInputObject["pattern"] as? String {
                return truncatedPreview(forToolName: toolName, bodyText: patternText)
            }
            if let promptText = parsedInputObject["prompt"] as? String {
                return truncatedPreview(forToolName: toolName, bodyText: promptText)
            }
            if let descriptionText = parsedInputObject["description"] as? String {
                return truncatedPreview(forToolName: toolName, bodyText: descriptionText)
            }
        }

        return truncatedPreview(forToolName: toolName, bodyText: trimmedInputJSON)
    }

    private func truncatedPreview(forToolName toolName: String, bodyText: String) -> String {
        let flattenedBodyText = bodyText
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
        let maximumPreviewLength = 140
        if flattenedBodyText.count > maximumPreviewLength {
            let truncatedPrefix = flattenedBodyText.prefix(maximumPreviewLength)
            return "\(truncatedPrefix)…"
        }
        return flattenedBodyText
    }

    private func parseUserMessageFrame(_ frameJSON: [String: Any]) -> [String] {
        guard let message = frameJSON["message"] as? [String: Any],
              let contentBlocks = message["content"] as? [[String: Any]] else {
            return []
        }

        var producedLines: [String] = []
        for contentBlock in contentBlocks {
            guard (contentBlock["type"] as? String) == "tool_result" else { continue }

            var toolResultText = ""
            if let toolResultContentString = contentBlock["content"] as? String {
                toolResultText = toolResultContentString
            } else if let toolResultContentBlocks = contentBlock["content"] as? [[String: Any]] {
                for innerBlock in toolResultContentBlocks {
                    if let innerText = innerBlock["text"] as? String {
                        toolResultText += innerText
                    }
                }
            }

            let trimmedResultText = toolResultText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedResultText.isEmpty else {
                producedLines.append("← (empty tool result)")
                continue
            }

            // Render only the first non-empty line of the result plus a
            // truncation marker if the full result is longer — otherwise
            // tool results can flood the sidebar.
            let firstNonEmptyResultLine = trimmedResultText
                .split(whereSeparator: { $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first(where: { !$0.isEmpty }) ?? trimmedResultText
            let maximumPreviewLength = 140
            let truncatedLine: String
            if firstNonEmptyResultLine.count > maximumPreviewLength {
                truncatedLine = "\(firstNonEmptyResultLine.prefix(maximumPreviewLength))…"
            } else {
                truncatedLine = firstNonEmptyResultLine
            }

            let resultHadMultipleLines = trimmedResultText.contains("\n")
            producedLines.append("← \(truncatedLine)\(resultHadMultipleLines ? " (more hidden)" : "")")
        }

        return producedLines
    }

    private func parseResultFrame(_ frameJSON: [String: Any]) -> [String] {
        // Flush any dangling assistant text before the final line so no
        // prose gets dropped if Claude Code ended without a trailing
        // content_block_stop.
        var producedLines: [String] = flushAssistantAccumulator()

        let subtype = (frameJSON["subtype"] as? String) ?? "unknown"
        let durationMilliseconds = (frameJSON["duration_ms"] as? Double).map { Int($0) } ?? 0
        let numberOfTurns = (frameJSON["num_turns"] as? Int) ?? 0
        let totalCostUSD = (frameJSON["total_cost_usd"] as? Double) ?? 0.0

        let turnsLabel = numberOfTurns == 1 ? "turn" : "turns"
        let formattedCostString = String(format: "%.4f", totalCostUSD)

        producedLines.append("")
        producedLines.append("✓ result: \(subtype) · \(numberOfTurns) \(turnsLabel) · \(durationMilliseconds)ms · $\(formattedCostString)")
        return producedLines
    }
}

// MARK: - Per-session state

/// Owns a single delegation's panel, log polling timer, and process
/// lifecycle watcher. Multiple sessions coexist — each represents one
/// live coding-agent run and lives until the user closes it.
@MainActor
private final class DelegationLogSidebarSession {
    let sessionID = UUID()
    let workspacePath: String
    /// Stable identifier for the workspace this session belongs to.
    /// Used by the queue manager to look up the right per-workspace
    /// queue when this session completes.
    let workspaceID: UUID
    let runtimeID: DelegationAgentRuntimeID
    let viewModel = DelegationLogSidebarViewModel()

    var sidebarPanel: NSPanel?
    var logPollingTimer: Timer?
    var processMonitoringTimer: Timer?
    var monitoredLogFileURL: URL?
    var currentReadOffset: UInt64 = 0
    var monitoredProcessIdentifier: Int32?

    /// Invoked once when the delegated process is observed to have
    /// exited (after the commit-count check has run). The queue
    /// manager uses this hook to promote the next queued delegation
    /// for the same workspace.
    var onProcessCompleteCallback: (() -> Void)?

    /// Stateful parser for Claude Code's `--output-format stream-json`
    /// frames. Only populated when `runtimeID == .claude`; Codex and
    /// OpenCode write plain text that the sidebar renders verbatim.
    var claudeStreamJSONParser: DelegationLogClaudeStreamJSONParser?

    static let expandedWidth: CGFloat = 360
    static let expandedHeight: CGFloat = 520
    static let minimizedHeight: CGFloat = 64
    static let maxVisibleLogLines = 320

    init(
        workspacePath: String,
        workspaceID: UUID,
        runtimeID: DelegationAgentRuntimeID
    ) {
        self.workspacePath = workspacePath
        self.workspaceID = workspaceID
        self.runtimeID = runtimeID
        if runtimeID == .claude {
            self.claudeStreamJSONParser = DelegationLogClaudeStreamJSONParser()
        }
    }
}

// MARK: - Coordinator / manager

/// Coordinates zero or more concurrent delegation log sidebar sessions
/// across workspaces. Sessions start their lives in the `queued` state
/// via `createQueuedSession` and are later transitioned to running via
/// `promoteQueuedSessionToRunning` once the per-workspace queue in
/// `CompanionManager` lets them pick up. Each session has its own
/// independent panel and monitoring timers, stacked along the right
/// edge of the cursor's screen.
@MainActor
final class DelegationLogSidebarManager {
    private var activeSessions: [UUID: DelegationLogSidebarSession] = [:]

    private static let rightEdgeInset: CGFloat = 18
    private static let verticalStackSpacing: CGFloat = 14

    /// Creates a new sidebar session in the **queued** state and
    /// returns its identifier. The session has no log tail, no
    /// process watcher, and no working branch yet — those are
    /// populated later via `promoteQueuedSessionToRunning` when the
    /// per-workspace queue allows this delegation to start. Pass
    /// `initialQueuePositionText` as the user-visible description
    /// (e.g. "next up", "position 2") so the panel can show it.
    @discardableResult
    func createQueuedSession(
        workspaceName: String,
        workspacePath: String,
        workspaceID: UUID,
        runtimeID: DelegationAgentRuntimeID,
        runtimeDisplayName: String,
        userTranscriptPreview: String,
        initialQueuePositionText: String
    ) -> UUID {
        let session = DelegationLogSidebarSession(
            workspacePath: workspacePath,
            workspaceID: workspaceID,
            runtimeID: runtimeID
        )

        session.viewModel.workspaceName = workspaceName
        session.viewModel.runtimeDisplayName = runtimeDisplayName
        session.viewModel.isQueuedWaitingForPickup = true
        session.viewModel.isProcessComplete = false
        session.viewModel.isMinimized = false
        session.viewModel.commitsAheadOfBaseCount = -1
        session.viewModel.statusText = initialQueuePositionText
        session.viewModel.visibleLogLines = buildQueuedSessionLogLines(
            workspaceName: workspaceName,
            runtimeDisplayName: runtimeDisplayName,
            userTranscriptPreview: userTranscriptPreview,
            initialQueuePositionText: initialQueuePositionText
        )

        activeSessions[session.sessionID] = session

        createPanelForSessionIfNeeded(session)
        repositionAllSessionsAlongRightEdge()
        session.sidebarPanel?.alphaValue = 1
        session.sidebarPanel?.orderFrontRegardless()

        // Deliberately do NOT start log polling or process monitoring
        // — the session has no log file or PID yet. Both timers are
        // started when the session is promoted to running.

        return session.sessionID
    }

    /// Transitions a queued sidebar session into the running state
    /// once its turn in the per-workspace queue arrives. Populates
    /// the log file URL, PID, branch metadata, and PR URL, then kicks
    /// off log tailing and process-lifecycle monitoring. Also wires
    /// up the callback the queue manager uses to advance the queue
    /// when this delegation eventually exits.
    func promoteQueuedSessionToRunning(
        sessionID: UUID,
        logFileURL: URL,
        processIdentifier: Int32,
        baseBranchName: String,
        workingBranchName: String,
        comparePullRequestURL: URL?,
        onProcessCompleteCallback: @escaping () -> Void
    ) {
        guard let session = activeSessions[sessionID] else { return }

        session.monitoredLogFileURL = logFileURL
        session.monitoredProcessIdentifier = processIdentifier
        session.currentReadOffset = 0
        session.onProcessCompleteCallback = onProcessCompleteCallback

        session.viewModel.isQueuedWaitingForPickup = false
        session.viewModel.logFilePath = logFileURL.path
        session.viewModel.baseBranchName = baseBranchName
        session.viewModel.workingBranchName = workingBranchName
        session.viewModel.comparePullRequestURL = comparePullRequestURL
        session.viewModel.isProcessComplete = false
        session.viewModel.statusText = "Streaming live \(session.viewModel.runtimeDisplayName) output"

        // Append the boot banner on top of whatever queued preamble
        // was already in the log lines, so the user can see the
        // transition from "waiting" to "picked up, agent running".
        let bootBannerLines = [
            "",
            "✓ picked up from queue — starting agent",
            "flowee delegation boot sequence engaged",
            "workspace: \(session.viewModel.workspaceName)",
            "agent: \(session.viewModel.runtimeDisplayName)",
            "log file: \(logFileURL.lastPathComponent)",
            "branch: \(baseBranchName) -> \(workingBranchName)",
            ""
        ]
        for bannerLine in bootBannerLines {
            session.viewModel.visibleLogLines.append(bannerLine)
        }
        session.viewModel.latestLogActivityAt = Date()

        startPollingLogFile(for: session)
        startMonitoringProcessLifecycle(for: session)
    }

    /// Updates the user-visible queue-position string for a queued
    /// session — called by the queue manager when other delegations
    /// ahead of this one complete and this one moves up the line.
    func updateQueuePositionText(sessionID: UUID, newQueuePositionText: String) {
        guard let session = activeSessions[sessionID],
              session.viewModel.isQueuedWaitingForPickup else { return }
        session.viewModel.statusText = newQueuePositionText

        let updatedQueueLine = "queue: \(newQueuePositionText)"
        // Replace any existing `queue: ...` line in the visible lines
        // so the panel shows the current position without piling up
        // stale ones.
        if let existingIndex = session.viewModel.visibleLogLines.firstIndex(where: { $0.hasPrefix("queue: ") }) {
            session.viewModel.visibleLogLines[existingIndex] = updatedQueueLine
        } else {
            session.viewModel.visibleLogLines.append(updatedQueueLine)
        }
        session.viewModel.latestLogActivityAt = Date()
    }

    /// Marks a session as failed — used when the delegation launcher
    /// throws before the session ever transitions to running (e.g.
    /// `git checkout -b` fails because the user has uncommitted
    /// changes that would conflict with main).
    func markQueuedSessionAsFailed(sessionID: UUID, errorMessage: String) {
        guard let session = activeSessions[sessionID] else { return }
        session.viewModel.isQueuedWaitingForPickup = false
        session.viewModel.isProcessComplete = true
        session.viewModel.statusText = "Launch failed"
        session.viewModel.visibleLogLines.append("")
        session.viewModel.visibleLogLines.append("⚠ delegation launch failed:")
        session.viewModel.visibleLogLines.append("   \(errorMessage)")
        session.viewModel.latestLogActivityAt = Date()
        stopPollingLogFile(for: session)
        stopMonitoringProcessLifecycle(for: session)
    }

    /// Returns true if there is currently a session in this workspace
    /// that is actually running an agent process (not queued, not
    /// complete). Used by the queue manager to decide whether a new
    /// delegation should start immediately or be enqueued.
    func hasRunningSession(forWorkspaceID workspaceID: UUID) -> Bool {
        return activeSessions.values.contains { session in
            session.workspaceID == workspaceID
                && !session.viewModel.isQueuedWaitingForPickup
                && !session.viewModel.isProcessComplete
        }
    }

    private func buildQueuedSessionLogLines(
        workspaceName: String,
        runtimeDisplayName: String,
        userTranscriptPreview: String,
        initialQueuePositionText: String
    ) -> [String] {
        var lines: [String] = [
            "⏳ flowee delegation queued",
            "workspace: \(workspaceName)",
            "agent: \(runtimeDisplayName)",
            "queue: \(initialQueuePositionText)",
            ""
        ]
        let trimmedTranscriptPreview = userTranscriptPreview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTranscriptPreview.isEmpty {
            lines.append("your request:")
            lines.append(trimmedTranscriptPreview)
            lines.append("")
        }
        lines.append("waiting for previous delegation in this workspace to finish...")
        return lines
    }

    /// Closes and tears down a single session, leaving any other running
    /// delegations untouched.
    func hideSession(sessionID: UUID) {
        guard let session = activeSessions[sessionID] else { return }
        stopPollingLogFile(for: session)
        stopMonitoringProcessLifecycle(for: session)
        session.sidebarPanel?.orderOut(nil)
        session.sidebarPanel = nil
        activeSessions.removeValue(forKey: sessionID)
        repositionAllSessionsAlongRightEdge()
    }

    /// Tears down every active session. Used when the companion shuts
    /// down or permissions are revoked.
    func hideAllSessions() {
        let allSessionIDs = Array(activeSessions.keys)
        for sessionID in allSessionIDs {
            hideSession(sessionID: sessionID)
        }
    }

    /// Collapses a session's panel to a compact title bar. Clicking the
    /// compact bar calls `toggleMinimized` again and the panel expands.
    func toggleMinimized(sessionID: UUID) {
        guard let session = activeSessions[sessionID] else { return }
        session.viewModel.isMinimized.toggle()
        repositionAllSessionsAlongRightEdge()
    }

    // MARK: Panel construction

    private func createPanelForSessionIfNeeded(_ session: DelegationLogSidebarSession) {
        if session.sidebarPanel != nil { return }

        let initialFrame = NSRect(
            x: 0,
            y: 0,
            width: DelegationLogSidebarSession.expandedWidth,
            height: DelegationLogSidebarSession.expandedHeight
        )
        let panel = NonKeyingBorderlessPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isExcludedFromWindowsMenu = true

        let capturedSessionID = session.sessionID
        let hostingView = NSHostingView(
            rootView: DelegationLogSidebarView(
                viewModel: session.viewModel,
                onCloseSidebarRequested: { [weak self] in
                    self?.hideSession(sessionID: capturedSessionID)
                },
                onMinimizeRequested: { [weak self] in
                    self?.toggleMinimized(sessionID: capturedSessionID)
                },
                onRestoreRequested: { [weak self] in
                    self?.toggleMinimized(sessionID: capturedSessionID)
                }
            )
        )
        hostingView.frame = initialFrame
        panel.contentView = hostingView

        session.sidebarPanel = panel
    }

    /// Stacks every active session's panel along the right edge of the
    /// screen that currently contains the cursor. Minimized sessions take
    /// much less vertical space, allowing many sessions to coexist.
    private func repositionAllSessionsAlongRightEdge() {
        let orderedSessions = activeSessions.values.sorted { leftSession, rightSession in
            leftSession.sessionID.uuidString < rightSession.sessionID.uuidString
        }

        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let visibleFrame = targetScreen?.visibleFrame ?? NSScreen.screens.first?.visibleFrame ?? .zero

        let totalStackedHeight = orderedSessions.reduce(0.0) { runningTotal, session in
            let sessionHeight: CGFloat = session.viewModel.isMinimized
                ? DelegationLogSidebarSession.minimizedHeight
                : DelegationLogSidebarSession.expandedHeight
            return runningTotal + sessionHeight
        }
        let totalSpacingHeight = max(0, CGFloat(orderedSessions.count - 1)) * Self.verticalStackSpacing
        let stackStartY = visibleFrame.midY + ((totalStackedHeight + totalSpacingHeight) / 2)

        var currentTopY = stackStartY
        let panelOriginX = visibleFrame.maxX - DelegationLogSidebarSession.expandedWidth - Self.rightEdgeInset

        for session in orderedSessions {
            guard let sidebarPanel = session.sidebarPanel else { continue }
            let panelHeight: CGFloat = session.viewModel.isMinimized
                ? DelegationLogSidebarSession.minimizedHeight
                : DelegationLogSidebarSession.expandedHeight
            let panelOriginY = currentTopY - panelHeight

            sidebarPanel.setFrame(
                NSRect(
                    x: panelOriginX,
                    y: panelOriginY,
                    width: DelegationLogSidebarSession.expandedWidth,
                    height: panelHeight
                ),
                display: true
            )

            // Keep the hosting view's frame in sync so SwiftUI re-lays out
            // against the new height when toggling minimize/restore.
            if let hostingView = sidebarPanel.contentView {
                hostingView.frame = NSRect(
                    x: 0,
                    y: 0,
                    width: DelegationLogSidebarSession.expandedWidth,
                    height: panelHeight
                )
            }

            currentTopY = panelOriginY - Self.verticalStackSpacing
        }
    }

    // MARK: Log file tailing

    private func startPollingLogFile(for session: DelegationLogSidebarSession) {
        stopPollingLogFile(for: session)
        let capturedSessionID = session.sessionID
        session.logPollingTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollLogFileForNewContent(sessionID: capturedSessionID)
            }
        }
    }

    private func stopPollingLogFile(for session: DelegationLogSidebarSession) {
        session.logPollingTimer?.invalidate()
        session.logPollingTimer = nil
    }

    private func pollLogFileForNewContent(sessionID: UUID) {
        guard let session = activeSessions[sessionID],
              let monitoredLogFileURL = session.monitoredLogFileURL else { return }

        do {
            let fileHandle = try FileHandle(forReadingFrom: monitoredLogFileURL)
            try fileHandle.seek(toOffset: session.currentReadOffset)
            let newData = fileHandle.readDataToEndOfFile()
            fileHandle.closeFile()

            guard !newData.isEmpty else { return }

            session.currentReadOffset += UInt64(newData.count)

            if let newText = String(data: newData, encoding: .utf8), !newText.isEmpty {
                appendLogText(newText, to: session)
            }
        } catch {
            session.viewModel.statusText = "Log stream interrupted"
        }
    }

    private func appendLogText(_ text: String, to session: DelegationLogSidebarSession) {
        // Claude runtime: feed the raw bytes into the stream-json parser
        // and push whatever semantic lines it produces into the view
        // model. Codex and OpenCode continue to use the plain-text path.
        let linesToAppend: [String]
        if session.runtimeID == .claude, let claudeStreamJSONParser = session.claudeStreamJSONParser {
            linesToAppend = claudeStreamJSONParser.ingest(rawText: text)
        } else {
            let normalizedLines = text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
            linesToAppend = normalizedLines.filter { !$0.isEmpty }
        }

        for line in linesToAppend {
            session.viewModel.visibleLogLines.append(line)
        }

        if session.viewModel.visibleLogLines.count > DelegationLogSidebarSession.maxVisibleLogLines {
            session.viewModel.visibleLogLines.removeFirst(
                session.viewModel.visibleLogLines.count - DelegationLogSidebarSession.maxVisibleLogLines
            )
        }

        session.viewModel.latestLogActivityAt = Date()
    }

    // MARK: Process lifecycle

    private func startMonitoringProcessLifecycle(for session: DelegationLogSidebarSession) {
        stopMonitoringProcessLifecycle(for: session)
        let capturedSessionID = session.sessionID
        session.processMonitoringTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollProcessLifecycle(sessionID: capturedSessionID)
            }
        }
    }

    private func stopMonitoringProcessLifecycle(for session: DelegationLogSidebarSession) {
        session.processMonitoringTimer?.invalidate()
        session.processMonitoringTimer = nil
    }

    private func pollProcessLifecycle(sessionID: UUID) {
        guard let session = activeSessions[sessionID] else { return }
        guard let monitoredProcessIdentifier = session.monitoredProcessIdentifier,
              monitoredProcessIdentifier > 0 else { return }
        guard !session.viewModel.isProcessComplete else { return }

        let processStillRunning = kill(monitoredProcessIdentifier, 0) == 0
        if processStillRunning {
            return
        }

        // Drain one last read from the log file in case the process
        // flushed its final bytes between the log-polling tick and now.
        pollLogFileForNewContent(sessionID: sessionID)

        // Flush any buffered-but-not-yet-newline-terminated content out
        // of the Claude stream-json parser. Claude Code's final `result`
        // frame sometimes lands without a trailing newline right before
        // exit, and without this flush the `✓ result · ...` summary
        // would never show up in the sidebar.
        if session.runtimeID == .claude,
           let claudeStreamJSONParser = session.claudeStreamJSONParser {
            let flushedSemanticLines = claudeStreamJSONParser.flushPendingBuffer()
            for flushedSemanticLine in flushedSemanticLines {
                session.viewModel.visibleLogLines.append(flushedSemanticLine)
            }
            if !flushedSemanticLines.isEmpty {
                session.viewModel.latestLogActivityAt = Date()
            }
        }

        session.viewModel.isProcessComplete = true

        // Count how many commits the agent made on the working branch
        // so we can warn the user immediately if the run produced zero
        // commits (which would make any pull request empty). Run this
        // as a detached Task so the main actor doesn't block on git.
        // After the commit check runs, fire the queue-advance
        // callback so the next delegation queued behind this one in
        // the same workspace can be promoted from queued to running.
        let capturedSessionID = session.sessionID
        let capturedWorkspacePath = session.workspacePath
        let capturedBaseBranchName = session.viewModel.baseBranchName
        let capturedWorkingBranchName = session.viewModel.workingBranchName
        Task.detached { [weak self] in
            let commitsAheadCount = countCommitsAhead(
                baseBranchName: capturedBaseBranchName,
                workingBranchName: capturedWorkingBranchName,
                workspaceDirectoryPath: capturedWorkspacePath
            )
            await MainActor.run { [weak self] in
                guard let self,
                      let sessionStillActive = self.activeSessions[capturedSessionID] else { return }
                sessionStillActive.viewModel.commitsAheadOfBaseCount = commitsAheadCount

                if commitsAheadCount <= 0 {
                    sessionStillActive.viewModel.statusText = "Agent run complete — but no commits were made."
                    self.appendLogText(
                        """

                        flowee detected that the delegated agent finished.
                        ⚠ WARNING: the agent exited without committing any changes on \(capturedWorkingBranchName). any pull request will be empty. check \(capturedWorkspacePath) for uncommitted work, or re-run the delegation.
                        """,
                        to: sessionStillActive
                    )
                } else {
                    let commitsLabel = commitsAheadCount == 1 ? "commit" : "commits"
                    sessionStillActive.viewModel.statusText = "Agent run complete — \(commitsAheadCount) \(commitsLabel) ready. Raise a PR when you're ready."
                    self.appendLogText(
                        """

                        flowee detected that the delegated agent finished.
                        ✓ \(commitsAheadCount) \(commitsLabel) on \(capturedWorkingBranchName) ahead of \(capturedBaseBranchName).
                        next move: raise a pr from \(capturedWorkingBranchName) into \(capturedBaseBranchName).
                        """,
                        to: sessionStillActive
                    )
                }

                // Fire the queue-advance callback so whatever
                // delegation is queued behind this one (if any) can
                // be promoted from queued to running. The callback
                // is fired exactly once per session.
                let callback = sessionStillActive.onProcessCompleteCallback
                sessionStillActive.onProcessCompleteCallback = nil
                callback?()
            }
        }

        stopMonitoringProcessLifecycle(for: session)
    }
}

/// Runs `git rev-list --count <base>..<working>` in the user's
/// workspace and returns the number of commits the working branch is
/// ahead of the base branch. Returns 0 on any failure so the caller
/// surfaces a conservative "no commits" warning rather than pretending
/// everything is fine. This lives at file scope so the detached Task in
/// `pollProcessLifecycle` can call it off the main actor.
private func countCommitsAhead(
    baseBranchName: String,
    workingBranchName: String,
    workspaceDirectoryPath: String
) -> Int {
    let gitBinaryCandidatePaths = [
        "/usr/bin/git",
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git"
    ]
    guard let gitBinaryPath = gitBinaryCandidatePaths.first(where: {
        FileManager.default.isExecutableFile(atPath: $0)
    }) else {
        return 0
    }

    let gitProcess = Process()
    gitProcess.executableURL = URL(fileURLWithPath: gitBinaryPath)
    gitProcess.currentDirectoryURL = URL(fileURLWithPath: workspaceDirectoryPath, isDirectory: true)
    gitProcess.arguments = [
        "rev-list",
        "--count",
        "\(baseBranchName)..\(workingBranchName)"
    ]

    let standardOutputPipe = Pipe()
    let standardErrorPipe = Pipe()
    gitProcess.standardOutput = standardOutputPipe
    gitProcess.standardError = standardErrorPipe

    do {
        try gitProcess.run()
    } catch {
        return 0
    }
    gitProcess.waitUntilExit()

    guard gitProcess.terminationStatus == 0 else {
        return 0
    }

    let standardOutputData = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
    let standardOutputText = String(data: standardOutputData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return Int(standardOutputText) ?? 0
}

// MARK: - SwiftUI view

private struct DelegationLogSidebarView: View {
    @ObservedObject var viewModel: DelegationLogSidebarViewModel
    let onCloseSidebarRequested: () -> Void
    let onMinimizeRequested: () -> Void
    let onRestoreRequested: () -> Void
    @State private var scanSweepOffset: CGFloat = -420
    @State private var headerPulseOpacity: Double = 0.45
    @State private var logActivityIntensity: Double = 0.0
    @State private var isHoveringMacCloseButton: Bool = false
    @State private var isHoveringMacMinimizeButton: Bool = false

    var body: some View {
        Group {
            if viewModel.isMinimized {
                minimizedBarBody
            } else {
                expandedBody
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) {
                scanSweepOffset = 620
            }

            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                headerPulseOpacity = 0.90
            }
        }
        .onChange(of: viewModel.latestLogActivityAt) {
            triggerLogActivityPulse()
        }
    }

    private var expandedBody: some View {
        ZStack {
            backgroundLayer
            scanlineLayer
            animatedSweepLayer

            VStack(alignment: .leading, spacing: 14) {
                macWindowControlsRow
                headerSection
                logBodySection
                footerSection
                if viewModel.isProcessComplete {
                    completedPullRequestBar
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                // Dim the border while the session is still sitting
                // in the per-workspace queue so queued panels look
                // visually distinct from live ones.
                .stroke(
                    DS.Colors.brandGradientStart.opacity(
                        viewModel.isQueuedWaitingForPickup ? 0.18 : 0.40
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.45), radius: 18, x: 0, y: 12)
        .shadow(color: DS.Colors.brandGradientEnd.opacity(0.14), radius: 16, x: 0, y: 0)
    }

    // Compact bar shown when the session is minimized. The whole bar
    // (except for the traffic-light buttons) is a click target that
    // restores the expanded view.
    private var minimizedBarBody: some View {
        ZStack {
            backgroundLayer

            HStack(spacing: 10) {
                macWindowControlsRow
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.workspaceName.uppercased())
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                    Text(minimizedStatusLine)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(DS.Colors.brandGradientStart)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    onRestoreRequested()
                }
                .pointerCursor()
                .help("Click to restore delegation stream")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DS.Colors.brandGradientStart.opacity(0.40), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.45), radius: 12, x: 0, y: 6)
    }

    private var minimizedStatusLine: String {
        if viewModel.isQueuedWaitingForPickup {
            return "queued · \(viewModel.runtimeDisplayName.lowercased())"
        }
        if viewModel.isProcessComplete {
            return "complete · \(viewModel.runtimeDisplayName.lowercased())"
        }
        return "streaming · \(viewModel.runtimeDisplayName.lowercased())"
    }

    private var backgroundLayer: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        DS.Colors.blue950.opacity(0.96),
                        Color(red: 0.09, green: 0.02, blue: 0.16),
                        Color.black.opacity(0.98)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private var scanlineLayer: some View {
        GeometryReader { geometry in
            let lineCount = Int(geometry.size.height / 4)
            VStack(spacing: 2) {
                ForEach(0..<lineCount, id: \.self) { _ in
                    Rectangle()
                        .fill(DS.Colors.brandGradientStart.opacity(0.028))
                        .frame(height: 1)
                    Spacer(minLength: 0)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var animatedSweepLayer: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            DS.Colors.brandGradientStart.opacity(0.0),
                            DS.Colors.brandGlow.opacity(0.10 + (logActivityIntensity * 0.20)),
                            DS.Colors.brandGradientEnd.opacity(0.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: geometry.size.width * 0.65, height: 90)
                .blur(radius: 18 - (logActivityIntensity * 4))
                .rotationEffect(.degrees(-9))
                .offset(x: scanSweepOffset, y: -geometry.size.height * 0.18)
                .opacity(0.55 + (logActivityIntensity * 0.35))
        }
        .allowsHitTesting(false)
    }

    // Mimics the classic macOS window traffic-light controls. Red closes
    // the session, yellow toggles minimized/expanded, green is decorative.
    private var macWindowControlsRow: some View {
        HStack(spacing: 8) {
            Button(action: {
                onCloseSidebarRequested()
            }) {
                ZStack {
                    Circle()
                        .fill(Color(red: 1.0, green: 0.37, blue: 0.34))
                        .overlay(
                            Circle()
                                .stroke(Color.black.opacity(0.22), lineWidth: 0.5)
                        )
                        .shadow(color: Color.black.opacity(0.35), radius: 1, x: 0, y: 0.5)

                    if isHoveringMacCloseButton {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(Color.black.opacity(0.62))
                    }
                }
                .frame(width: 13, height: 13)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .onHover { hovering in
                isHoveringMacCloseButton = hovering
            }
            .help("Close delegation stream")

            Button(action: {
                onMinimizeRequested()
            }) {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.98, green: 0.75, blue: 0.18))
                        .overlay(
                            Circle()
                                .stroke(Color.black.opacity(0.22), lineWidth: 0.5)
                        )
                        .shadow(color: Color.black.opacity(0.35), radius: 1, x: 0, y: 0.5)

                    if isHoveringMacMinimizeButton {
                        Image(systemName: viewModel.isMinimized ? "plus" : "minus")
                            .font(.system(size: 8, weight: .black))
                            .foregroundColor(Color.black.opacity(0.62))
                    }
                }
                .frame(width: 13, height: 13)
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .onHover { hovering in
                isHoveringMacMinimizeButton = hovering
            }
            .help(viewModel.isMinimized ? "Restore delegation stream" : "Minimize delegation stream")

            Circle()
                .fill(Color(red: 0.24, green: 0.78, blue: 0.27))
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.22), lineWidth: 0.5)
                )
                .frame(width: 13, height: 13)
                .opacity(0.55)

            Spacer()
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(DS.Colors.brandGlow)
                    .frame(width: 8, height: 8)
                    .shadow(color: DS.Colors.brandGlow.opacity(headerPulseOpacity + (logActivityIntensity * 0.35)), radius: 10 + (logActivityIntensity * 6), x: 0, y: 0)
                    .opacity(min(headerPulseOpacity + (logActivityIntensity * 0.25), 1.0))

                Text("DELEGATION STREAM")
                    .font(.system(size: 18, weight: .black, design: .monospaced))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                DS.Colors.brandGradientStart,
                                DS.Colors.brandGlow
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .shadow(color: DS.Colors.brandGradientEnd.opacity(0.48), radius: 10, x: 0, y: 0)
            }

            Text(viewModel.workspaceName.uppercased())
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(DS.Colors.textPrimary)

            Text(viewModel.statusText)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(DS.Colors.brandGradientStart)

            Text(viewModel.logFilePath)
                .font(.system(size: 9, weight: .regular, design: .monospaced))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(2)
        }
    }

    private var logBodySection: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                Text(viewModel.joinedLogText.isEmpty ? "awaiting first output frame..." : viewModel.joinedLogText)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(Color(red: 0.90, green: 0.82, blue: 1.0))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .id("delegation-log-bottom")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.42))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(DS.Colors.brandGradientEnd.opacity(0.30), lineWidth: 0.8)
                    )
            )
            .onChange(of: viewModel.joinedLogText) {
                withAnimation(.easeOut(duration: 0.18)) {
                    scrollProxy.scrollTo("delegation-log-bottom", anchor: .bottom)
                }
            }
        }
    }

    private var footerSection: some View {
        HStack {
            Text("streaming live \(viewModel.runtimeDisplayName.lowercased()) output")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(DS.Colors.brandGradientStart)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer()

            Text("FLOWEE")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(DS.Colors.brandGlow)
        }
    }

    private var completedPullRequestBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Raise a PR")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(DS.Colors.textPrimary)

                Text("\(viewModel.baseBranchName) ← \(viewModel.workingBranchName)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(DS.Colors.brandGradientStart)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: {
                openPullRequestDestinationIfAvailable()
            }) {
                Text(viewModel.comparePullRequestURL == nil ? "Ready" : "Open PR")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textOnAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        DS.Colors.brandGradientStart,
                                        DS.Colors.brandGradientEnd
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .disabled(viewModel.comparePullRequestURL == nil)
            .opacity(viewModel.comparePullRequestURL == nil ? 0.65 : 1.0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(DS.Colors.surface2.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(DS.Colors.brandGradientStart.opacity(0.32), lineWidth: 0.9)
                )
        )
    }

    private func triggerLogActivityPulse() {
        logActivityIntensity = 1.0

        withAnimation(.easeOut(duration: 0.9)) {
            logActivityIntensity = 0.0
        }

        scanSweepOffset = -420
        withAnimation(.linear(duration: 1.15)) {
            scanSweepOffset = 620
        }
    }

    private func openPullRequestDestinationIfAvailable() {
        guard let comparePullRequestURL = viewModel.comparePullRequestURL else { return }
        NSWorkspace.shared.open(comparePullRequestURL)
    }
}
