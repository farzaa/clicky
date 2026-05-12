//
//  ClaudeCodeAdapter.swift
//  leanring-buddy
//
//  Spawns the user's locally-installed Claude Code CLI (`claude`) and
//  translates its stream-json output into `AgentTaskEvent`s. Implements
//  `AgentWorker`. See docs/agent-tasks-design.md.
//
//  Authentication is the user's responsibility in v1 — they must have run
//  `claude` interactively at least once to log into their Anthropic account
//  or set ANTHROPIC_API_KEY. The subprocess inherits the user's filesystem
//  so the auth picks up automatically.
//

import Foundation

/// Worker adapter for Anthropic's Claude Code CLI.
@MainActor
final class ClaudeCodeAdapter: AgentWorker {

    nonisolated static let workerDisplayName: String = "Claude Code"

    /// Search paths the adapter walks to find an installed `claude` binary.
    /// GUI apps don't inherit the interactive shell's PATH, so we must look
    /// in the well-known install locations explicitly. First hit wins.
    nonisolated private static let candidateBinarySearchPaths: [String] = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "/opt/local/bin/claude",
        NSString(string: "~/.npm-global/bin/claude").expandingTildeInPath,
        NSString(string: "~/.bun/bin/claude").expandingTildeInPath,
        NSString(string: "~/.volta/bin/claude").expandingTildeInPath,
        NSString(string: "~/.local/bin/claude").expandingTildeInPath,
        NSString(string: "~/.claude/local/claude").expandingTildeInPath
    ]

    /// Explicit coding agents should stay headless and code-focused. Dot
    /// captures foreground page/PDF context before spawning the worker, so
    /// the worker normally does not need browser-control tools.
    nonisolated private static let codingAgentAllowedToolNames: [String] = [
        "Read",
        "Write",
        "Edit",
        "MultiEdit",
        "Glob",
        "Grep",
        "LS",
        "TodoWrite",
        "WebFetch",
        "WebSearch",
        "Bash"
    ]

    /// Long-running personal tasks can use Claude Code as the durable worker,
    /// but they need connected account tools for Gmail, Drive, browser, and
    /// deck/artifact creation. Bash is intentionally excluded here; if Google
    /// Slides/Drive/Canva cannot create the artifact, the worker should report
    /// that blocker instead of silently falling back to shell-generated files.
    nonisolated private static let personalConnectedTaskAllowedToolNames: [String] = [
        "Read",
        "Write",
        "Edit",
        "MultiEdit",
        "Glob",
        "Grep",
        "LS",
        "TodoWrite",
        "ToolSearch",
        "WebFetch",
        "WebSearch",
        "mcp__claude-in-chrome__browser_batch",
        "mcp__claude-in-chrome__computer",
        "mcp__claude-in-chrome__file_upload",
        "mcp__claude-in-chrome__find",
        "mcp__claude-in-chrome__form_input",
        "mcp__claude-in-chrome__get_page_text",
        "mcp__claude-in-chrome__javascript_tool",
        "mcp__claude-in-chrome__navigate",
        "mcp__claude-in-chrome__read_console_messages",
        "mcp__claude-in-chrome__read_network_requests",
        "mcp__claude-in-chrome__read_page",
        "mcp__claude-in-chrome__resize_window",
        "mcp__claude-in-chrome__shortcuts_execute",
        "mcp__claude-in-chrome__shortcuts_list",
        "mcp__claude-in-chrome__switch_browser",
        "mcp__claude-in-chrome__tabs_close_mcp",
        "mcp__claude-in-chrome__tabs_context_mcp",
        "mcp__claude-in-chrome__tabs_create_mcp",
        "mcp__claude-in-chrome__upload_image",
        "mcp__claude_ai_Gmail__get_thread",
        "mcp__claude_ai_Gmail__list_drafts",
        "mcp__claude_ai_Gmail__list_labels",
        "mcp__claude_ai_Gmail__search_threads",
        "mcp__claude_ai_Google_Drive__copy_file",
        "mcp__claude_ai_Google_Drive__create_file",
        "mcp__claude_ai_Google_Drive__download_file_content",
        "mcp__claude_ai_Google_Drive__get_file_metadata",
        "mcp__claude_ai_Google_Drive__list_recent_files",
        "mcp__claude_ai_Google_Drive__read_file_content",
        "mcp__claude_ai_Google_Drive__search_files",
        "mcp__claude_ai_Canva__commit-editing-transaction",
        "mcp__claude_ai_Canva__create-design-from-candidate",
        "mcp__claude_ai_Canva__export-design",
        "mcp__claude_ai_Canva__generate-design",
        "mcp__claude_ai_Canva__generate-design-structured",
        "mcp__claude_ai_Canva__get-design",
        "mcp__claude_ai_Canva__get-design-content",
        "mcp__claude_ai_Canva__get-design-pages",
        "mcp__claude_ai_Canva__get-export-formats",
        "mcp__claude_ai_Canva__perform-editing-operations",
        "mcp__claude_ai_Canva__start-editing-transaction"
    ]

    private static var cachedResolvedBinaryPath: String?

    /// Walks the candidate paths and returns the first one that exists and
    /// is executable. Result is cached for the lifetime of the process —
    /// installs/uninstalls during a single app run are not detected, which
    /// is fine for our purposes.
    static func resolveInstalledBinaryPath() async -> String? {
        if let cached = cachedResolvedBinaryPath {
            return cached
        }
        let fileManager = FileManager.default
        for candidatePath in candidateBinarySearchPaths {
            if fileManager.isExecutableFile(atPath: candidatePath) {
                cachedResolvedBinaryPath = candidatePath
                return candidatePath
            }
        }
        return nil
    }

    nonisolated static func isInstalledOnSystem() async -> Bool {
        return await resolveInstalledBinaryPath() != nil
    }

    nonisolated static func installInstructionMessage() -> String {
        return "Install Claude Code (npm install -g @anthropic-ai/claude-code) and run `claude` once to sign in."
    }

    // MARK: - Instance state

    private var runningProcess: Process?
    private var stdoutLineReader: ProcessLineReader?
    private var stderrLineReader: ProcessLineReader?
    private var stdinFileHandle: FileHandle?
    private var streamEventContinuation: AsyncThrowingStream<AgentTaskEvent, Error>.Continuation?
    private var hasYieldedTerminalEvent: Bool = false
    private var didReceiveSuccessfulCompletionEvent: Bool = false
    private var lastEmittedFailureReason: String?

    // MARK: - AgentWorker

    func spawn(brief: AgentTaskBrief) async throws -> AsyncThrowingStream<AgentTaskEvent, Error> {

        guard runningProcess == nil else {
            throw ClaudeCodeAdapterError.alreadyRunning
        }

        guard let resolvedBinaryPath = await Self.resolveInstalledBinaryPath() else {
            throw ClaudeCodeAdapterError.notInstalled(
                instruction: Self.installInstructionMessage()
            )
        }

        try ensureWorkingDirectoryExists(brief: brief)
        try writeBriefAsInstructionsFile(brief: brief)
        try initializeGitRepositoryIfMissing(at: brief.workingDirectoryURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolvedBinaryPath)
        process.currentDirectoryURL = brief.workingDirectoryURL
        process.arguments = Self.buildCLIArguments(brief: brief)
        process.environment = Self.buildChildEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        self.runningProcess = process
        self.stdinFileHandle = stdinPipe.fileHandleForWriting

        // makeStream returns the continuation up-front so we can set it on
        // the MainActor-isolated stored property without going through a
        // @Sendable init closure. The onTermination callback is the only
        // piece that crosses actors — we marshal back to MainActor inside.
        let (eventStream, continuation) = AsyncThrowingStream<AgentTaskEvent, Error>
            .makeStream()
        self.streamEventContinuation = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.terminateRunningProcessIfAlive()
            }
        }

        startStdoutLineReader(stdoutPipe: stdoutPipe)
        startStderrLineReader(stderrPipe: stderrPipe)

        process.terminationHandler = { [weak self] terminatedProcess in
            // Snapshot the Sendable values here so the actor hop below
            // doesn't need to capture the non-Sendable Process reference.
            let snapshottedExitStatus = terminatedProcess.terminationStatus
            let snapshottedTerminationReason = terminatedProcess.terminationReason
            Task { @MainActor [weak self] in
                self?.handleProcessTerminated(
                    exitStatus: snapshottedExitStatus,
                    terminationReason: snapshottedTerminationReason
                )
            }
        }

        do {
            DotDebugLogger.log("claude.code", "running process", metadata: [
                "binary": resolvedBinaryPath,
                "cwd": brief.workingDirectoryURL.path,
                "args": process.arguments?.joined(separator: " ") ?? ""
            ])
            try process.run()
            DotDebugLogger.log("claude.code", "process launched", metadata: [
                "pid": process.processIdentifier
            ])
        } catch {
            DotDebugLogger.log("claude.code", "process launch threw", metadata: [
                "error": error.localizedDescription
            ])
            self.runningProcess = nil
            self.stdinFileHandle = nil
            streamEventContinuation?.yield(.workerFailed(
                failureReason: "Failed to launch Claude Code: \(error.localizedDescription)"
            ))
            streamEventContinuation?.finish()
            throw error
        }

        streamEventContinuation?.yield(
            .workerStarted(workerDisplayName: Self.workerDisplayName)
        )

        sendInitialUserMessage(brief: brief)

        return eventStream
    }

    func sendFollowUpMessage(_ message: String) async throws {
        guard let stdinFileHandle else {
            throw ClaudeCodeAdapterError.processNotRunning
        }
        let payload: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": message
            ]
        ]
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        var lineData = jsonData
        lineData.append(0x0A) // newline
        do {
            try stdinFileHandle.write(contentsOf: lineData)
        } catch {
            throw ClaudeCodeAdapterError.followUpWriteFailed(underlying: error)
        }
    }

    func cancel() async {
        await terminateRunningProcessIfAlive()
    }

    // MARK: - Spawn helpers

    private static func buildCLIArguments(brief: AgentTaskBrief) -> [String] {
        // `--print` runs Claude Code in non-interactive mode (single conversation,
        // exit when done). `--input-format=stream-json` lets us write JSON
        // user-message lines to stdin; `--output-format=stream-json` makes Claude
        // Code emit one structured event per line on stdout. `--max-turns` caps
        // the tool-call budget. Background workers run in a generated task
        // workspace, so they must be able to use explicitly allowed coding
        // tools without an interactive approval prompt. Live browser/app work
        // stays in Dot's foreground computer-use loop.
        let allowedToolNames = brief.shouldUsePersonalConnectedTools
            ? Self.personalConnectedTaskAllowedToolNames
            : Self.codingAgentAllowedToolNames

        var arguments = [
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--permission-mode", "bypassPermissions",
            "--allowedTools", allowedToolNames.joined(separator: ","),
            "--max-turns", String(brief.maxToolCallSteps)
        ]
        if brief.shouldUsePersonalConnectedTools {
            arguments.append("--tools")
            arguments.append(allowedToolNames.joined(separator: ","))
            arguments.append("--chrome")
        }
        if !brief.additionalDirectoryURLs.isEmpty {
            arguments.append("--add-dir")
            arguments.append(contentsOf: brief.additionalDirectoryURLs.map(\.path))
        }
        return arguments
    }

    private static func buildChildEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        // GUI app launches with a stripped PATH that may not include the npm /
        // homebrew prefixes the user's `claude` install relies on. Add the
        // common bin dirs back so the child process can find node, git, etc.
        let existingPath = environment["PATH"] ?? ""
        let supplementalPathEntries = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            NSString(string: "~/.npm-global/bin").expandingTildeInPath,
            NSString(string: "~/.bun/bin").expandingTildeInPath,
            NSString(string: "~/.volta/bin").expandingTildeInPath
        ]
        let combinedPath = ([existingPath] + supplementalPathEntries)
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        environment["PATH"] = combinedPath

        // HOME must be set for Claude Code to find its config + credentials.
        if environment["HOME"] == nil {
            environment["HOME"] = NSHomeDirectory()
        }

        return environment
    }

    private func ensureWorkingDirectoryExists(brief: AgentTaskBrief) throws {
        try FileManager.default.createDirectory(
            at: brief.workingDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    /// Writes the user's request + detailed instructions to INSTRUCTIONS.md
    /// inside the working dir so the agent sees its own marching orders on
    /// disk via its standard file-reading tools. This is cleaner than
    /// stuffing all of it into the stdin user message.
    private func writeBriefAsInstructionsFile(brief: AgentTaskBrief) throws {
        let instructionsContent = """
        # Task: \(brief.oneLineTitle)

        ## User's original spoken request

        \(brief.userOriginalRequest)

        ## Detailed instructions

        \(brief.detailedInstructions)

        ## Notes for the agent

        - Working directory: this folder.
        - Step budget: \(brief.maxToolCallSteps) tool calls.
        - Soft wall-clock budget: \(brief.maxWallClockSeconds / 60) minutes.
        - When you are done, print a short summary line as your final assistant message so the user hears it spoken aloud.
        """
        let instructionsFileURL = brief.workingDirectoryURL.appendingPathComponent("INSTRUCTIONS.md")
        try instructionsContent.write(
            to: instructionsFileURL,
            atomically: true,
            encoding: .utf8
        )
    }

    private func initializeGitRepositoryIfMissing(at workingDirectoryURL: URL) throws {
        let gitMetaDirectoryURL = workingDirectoryURL.appendingPathComponent(".git")
        if FileManager.default.fileExists(atPath: gitMetaDirectoryURL.path) {
            return
        }
        // Run `git init` synchronously so the agent's first commits land in a
        // real repo. Failures are non-fatal — we just lose rollback affordance.
        let gitInitProcess = Process()
        gitInitProcess.currentDirectoryURL = workingDirectoryURL
        gitInitProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        gitInitProcess.arguments = ["git", "init", "--quiet"]
        gitInitProcess.environment = Self.buildChildEnvironment()
        do {
            try gitInitProcess.run()
            gitInitProcess.waitUntilExit()
        } catch {
            // Swallow — git not being available shouldn't block the task.
        }
    }

    private func sendInitialUserMessage(brief: AgentTaskBrief) {
        // The first user message points the agent at the on-disk instructions
        // file rather than re-pasting the whole brief. This keeps the stdin
        // payload small and survives long tasks where the model may re-read
        // the file later for context.
        //
        // We deliberately leave stdin open so mid-run follow-up messages
        // (delivered via voice while the task is running) can be appended.
        // Claude Code's stream-json input mode reads additional user
        // messages until the process exits or stdin closes.
        let initialMessageText = """
        Read INSTRUCTIONS.md in the current directory and complete the task it describes. \
        Work from this directory. \
        When finished, end with a one-sentence summary of what you delivered.
        """
        Task {
            try? await self.sendFollowUpMessage(initialMessageText)
        }
    }

    // MARK: - Stream readers

    private func startStdoutLineReader(stdoutPipe: Pipe) {
        let lineReader = ProcessLineReader(pipe: stdoutPipe) { [weak self] line in
            Task { @MainActor [weak self] in
                self?.handleStdoutLine(line)
            }
        }
        lineReader.start()
        stdoutLineReader = lineReader
    }

    private func startStderrLineReader(stderrPipe: Pipe) {
        let lineReader = ProcessLineReader(pipe: stderrPipe) { [weak self] line in
            Task { @MainActor [weak self] in
                self?.handleStderrLine(line)
            }
        }
        lineReader.start()
        stderrLineReader = lineReader
    }

    private func handleStdoutLine(_ rawLine: String) {
        let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else { return }

        guard let lineData = trimmedLine.data(using: .utf8),
              let parsedJSON = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            // Not JSON — Claude Code occasionally prints stray lines on warm-up.
            // Surface as a warning so users can see them in the panel for debug.
            yieldEvent(.warningEmitted(text: trimmedLine))
            return
        }

        translateClaudeCodeEventLine(parsedJSON: parsedJSON)
    }

    private func handleStderrLine(_ rawLine: String) {
        let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else { return }
        // Save the last stderr line so a non-zero exit can surface it as the
        // failure reason.
        lastEmittedFailureReason = trimmedLine
        yieldEvent(.warningEmitted(text: trimmedLine))
    }

    /// Maps one Claude Code stream-json event to zero-or-more `AgentTaskEvent`s.
    /// The reference shape of the JSON is documented at
    /// docs.anthropic.com/claude-code/sdk; we handle the subset we care about
    /// and ignore the rest rather than crash on schema drift.
    private func translateClaudeCodeEventLine(parsedJSON: [String: Any]) {
        guard let topLevelType = parsedJSON["type"] as? String else { return }

        switch topLevelType {

        case "system":
            // {"type":"system","subtype":"init","session_id":"...","tools":[...]}
            if let subtype = parsedJSON["subtype"] as? String, subtype == "init" {
                yieldEvent(.plannerPhase(description: "starting up"))
            }

        case "assistant":
            // {"type":"assistant","message":{"role":"assistant","content":[...]}}
            guard let messageObject = parsedJSON["message"] as? [String: Any],
                  let contentBlocks = messageObject["content"] as? [[String: Any]] else {
                return
            }
            for contentBlock in contentBlocks {
                translateAssistantContentBlock(contentBlock: contentBlock)
            }

        case "user":
            // {"type":"user","message":{"role":"user","content":[{"type":"tool_result", "is_error": ..., "content": ...}]}}
            guard let messageObject = parsedJSON["message"] as? [String: Any],
                  let contentBlocks = messageObject["content"] as? [[String: Any]] else {
                return
            }
            for contentBlock in contentBlocks {
                translateUserContentBlock(contentBlock: contentBlock)
            }

        case "result":
            // {"type":"result","subtype":"success","result":"<summary>","total_cost_usd":...}
            let resultSubtype = parsedJSON["subtype"] as? String ?? "unknown"
            let resultSummaryText = parsedJSON["result"] as? String ?? ""
            if resultSubtype == "success" {
                didReceiveSuccessfulCompletionEvent = true
                let summaryToEmit = resultSummaryText.isEmpty ? "Done." : resultSummaryText
                yieldEvent(.workerCompleted(finalSummary: summaryToEmit))
                finalizeStreamIfNotAlready()
            } else {
                let failureReason = resultSummaryText.isEmpty
                    ? "Claude Code reported failure (\(resultSubtype))"
                    : resultSummaryText
                lastEmittedFailureReason = failureReason
                yieldEvent(.workerFailed(failureReason: failureReason))
                finalizeStreamIfNotAlready()
            }

        default:
            // Unknown top-level type — ignore for forward-compat.
            return
        }
    }

    private func translateAssistantContentBlock(contentBlock: [String: Any]) {
        guard let blockType = contentBlock["type"] as? String else { return }
        switch blockType {
        case "text":
            if let textValue = contentBlock["text"] as? String {
                let trimmedText = textValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedText.isEmpty {
                    yieldEvent(.assistantMessage(text: trimmedText))
                }
            }
        case "tool_use":
            let toolName = contentBlock["name"] as? String ?? "tool"
            let inputArguments = contentBlock["input"] as? [String: Any] ?? [:]
            let oneLineSummary = summarizeToolCallInput(
                toolName: toolName,
                inputArguments: inputArguments
            )
            yieldEvent(.toolCallInvoked(name: toolName, oneLineSummary: oneLineSummary))
            // Surface file edits + shell commands as their own typed events too
            // so the panel can render them with appropriate styling.
            if toolName == "Edit" || toolName == "Write" {
                let filePathValue = inputArguments["file_path"] as? String ?? ""
                if !filePathValue.isEmpty {
                    yieldEvent(.fileEdit(filePath: filePathValue, summaryDiff: nil))
                }
            } else if toolName == "Bash" {
                let commandValue = inputArguments["command"] as? String ?? ""
                if !commandValue.isEmpty {
                    yieldEvent(.shellCommand(command: commandValue, output: nil))
                }
            }
        default:
            return
        }
    }

    private func translateUserContentBlock(contentBlock: [String: Any]) {
        guard let blockType = contentBlock["type"] as? String, blockType == "tool_result" else {
            return
        }
        let isError = contentBlock["is_error"] as? Bool ?? false
        if isError {
            let errorText = Self.flattenToolResultContent(contentBlock["content"]) ?? "tool error"
            yieldEvent(.warningEmitted(text: "tool error: \(errorText.prefix(200))"))
        }
    }

    /// Tool results are sometimes a string, sometimes an array of content
    /// blocks. We flatten to a single string for surfacing in warnings.
    private static func flattenToolResultContent(_ rawContent: Any?) -> String? {
        if let stringContent = rawContent as? String {
            return stringContent
        }
        if let contentBlockArray = rawContent as? [[String: Any]] {
            let combined = contentBlockArray.compactMap { block -> String? in
                if let textValue = block["text"] as? String { return textValue }
                return nil
            }.joined(separator: " ")
            return combined.isEmpty ? nil : combined
        }
        return nil
    }

    private func summarizeToolCallInput(
        toolName: String,
        inputArguments: [String: Any]
    ) -> String {
        switch toolName {
        case "Read":
            return (inputArguments["file_path"] as? String) ?? "read"
        case "Edit", "Write", "MultiEdit":
            return (inputArguments["file_path"] as? String) ?? toolName.lowercased()
        case "Bash":
            let commandValue = (inputArguments["command"] as? String) ?? "bash"
            return String(commandValue.prefix(80))
        case "Grep":
            let pattern = (inputArguments["pattern"] as? String) ?? ""
            return "grep \(pattern)"
        case "Glob":
            return (inputArguments["pattern"] as? String) ?? "glob"
        case "WebFetch", "WebSearch":
            return (inputArguments["url"] as? String)
                ?? (inputArguments["query"] as? String)
                ?? toolName.lowercased()
        default:
            return toolName
        }
    }

    // MARK: - Termination

    private func handleProcessTerminated(
        exitStatus: Int32,
        terminationReason: Process.TerminationReason
    ) {
        DotDebugLogger.log("claude.code", "process terminated", metadata: [
            "exitStatus": Int(exitStatus),
            "terminationReason": String(describing: terminationReason),
            "didReceiveSuccessfulCompletionEvent": didReceiveSuccessfulCompletionEvent,
            "lastEmittedFailureReason": lastEmittedFailureReason ?? ""
        ])
        stdoutLineReader?.stop()
        stderrLineReader?.stop()
        stdoutLineReader = nil
        stderrLineReader = nil
        stdinFileHandle?.closeFile()
        stdinFileHandle = nil

        if didReceiveSuccessfulCompletionEvent {
            // Already emitted .workerCompleted from the result event.
            finalizeStreamIfNotAlready()
            runningProcess = nil
            return
        }

        if terminationReason == .uncaughtSignal {
            // Most likely our own SIGTERM from cancel().
            yieldEvent(.workerCancelled)
            finalizeStreamIfNotAlready()
            runningProcess = nil
            return
        }

        if exitStatus != 0 {
            let exitFailureReason = lastEmittedFailureReason
                ?? "Claude Code exited with code \(exitStatus)"
            yieldEvent(.workerFailed(failureReason: exitFailureReason))
            finalizeStreamIfNotAlready()
            runningProcess = nil
            return
        }

        // Exit 0 with no result event — treat as completion without summary.
        yieldEvent(.workerCompleted(finalSummary: "Done."))
        finalizeStreamIfNotAlready()
        runningProcess = nil
    }

    private func terminateRunningProcessIfAlive() async {
        guard let runningProcess, runningProcess.isRunning else {
            return
        }
        runningProcess.terminate()
        // Grace period; escalate to SIGKILL if still alive.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if runningProcess.isRunning {
            kill(runningProcess.processIdentifier, SIGKILL)
        }
    }

    func terminateImmediatelyForAppShutdown() {
        guard let runningProcess, runningProcess.isRunning else {
            return
        }
        runningProcess.terminate()
    }

    // MARK: - Event yielding helpers

    private func yieldEvent(_ event: AgentTaskEvent) {
        guard !hasYieldedTerminalEvent else { return }
        switch event {
        case .workerCompleted, .workerFailed, .workerCancelled:
            hasYieldedTerminalEvent = true
        default:
            break
        }
        streamEventContinuation?.yield(event)
    }

    private func finalizeStreamIfNotAlready() {
        streamEventContinuation?.finish()
        streamEventContinuation = nil
    }
}

enum ClaudeCodeAdapterError: Error, LocalizedError {
    case alreadyRunning
    case notInstalled(instruction: String)
    case processNotRunning
    case followUpWriteFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "A Claude Code task is already running on this adapter."
        case .notInstalled(let instruction):
            return instruction
        case .processNotRunning:
            return "Claude Code process is not running."
        case .followUpWriteFailed(let underlying):
            return "Failed to send follow-up to Claude Code: \(underlying.localizedDescription)"
        }
    }
}

/// Background line reader for a Pipe. Reads one line at a time and invokes
/// the callback for each. Stops on EOF or when `stop()` is called.
private final class ProcessLineReader {
    private let pipe: Pipe
    private let onLine: (String) -> Void
    private var hasStopped: Bool = false
    private let lineBufferQueue = DispatchQueue(label: "ProcessLineReader.buffer")
    private var lineBuffer: Data = Data()

    init(pipe: Pipe, onLine: @escaping (String) -> Void) {
        self.pipe = pipe
        self.onLine = onLine
    }

    func start() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let availableData = handle.availableData
            if availableData.isEmpty {
                // EOF — drain whatever remains in the buffer.
                self.lineBufferQueue.async {
                    if !self.lineBuffer.isEmpty {
                        if let trailing = String(data: self.lineBuffer, encoding: .utf8) {
                            self.onLine(trailing)
                        }
                        self.lineBuffer.removeAll()
                    }
                }
                handle.readabilityHandler = nil
                return
            }
            self.lineBufferQueue.async {
                guard !self.hasStopped else { return }
                self.lineBuffer.append(availableData)
                self.drainCompleteLinesLocked()
            }
        }
    }

    func stop() {
        hasStopped = true
        pipe.fileHandleForReading.readabilityHandler = nil
    }

    private func drainCompleteLinesLocked() {
        // Scan the buffer for newlines, deliver complete lines, keep the
        // partial trailing line for the next chunk.
        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
            let lineData = lineBuffer.subdata(in: 0..<newlineIndex)
            lineBuffer.removeSubrange(0...newlineIndex)
            if let lineString = String(data: lineData, encoding: .utf8) {
                let strippedLine = lineString.hasSuffix("\r")
                    ? String(lineString.dropLast())
                    : lineString
                onLine(strippedLine)
            }
        }
    }
}
