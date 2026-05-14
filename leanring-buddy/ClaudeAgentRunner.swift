//
//  ClaudeAgentRunner.swift
//  leanring-buddy
//
//  Runs Claude via the locally-installed Claude Code CLI as a subprocess.
//  This lets the user's Claude Max subscription provide the quota instead
//  of pay-per-token API access through the Cloudflare Worker.
//
//  The public surface mirrors the previous `ClaudeAPI` class so the rest
//  of the app does not have to know how the response is being produced.
//
//  Prerequisite on the user's Mac:
//    1. Install Claude Code (https://claude.com/claude-code).
//    2. Run `claude` once and sign in with the Claude Max account.
//  After that, Clicky shells out to the same binary and inherits the
//  authenticated session — no API key is shipped in the app or worker.
//

import Foundation

enum ClaudeAgentRunnerError: LocalizedError {
    case claudeBinaryNotFound(searchedPaths: [String])
    case processFailedToStart(underlying: Error)
    case processFailed(exitCode: Int32, stderrSnippet: String)
    case unableToWriteInput(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .claudeBinaryNotFound(let searchedPaths):
            return "The Claude CLI was not found. Install Claude Code from https://claude.com/claude-code and run `claude` once to authenticate with your Max account. Searched: \(searchedPaths.joined(separator: ", "))."
        case .processFailedToStart(let underlying):
            return "Could not start the Claude subprocess: \(underlying.localizedDescription)"
        case .processFailed(let exitCode, let stderrSnippet):
            return "Claude exited with code \(exitCode): \(stderrSnippet)"
        case .unableToWriteInput(let underlying):
            return "Could not send input to the Claude subprocess: \(underlying.localizedDescription)"
        }
    }
}

/// Wraps the local `claude` CLI as if it were a network API client.
///
/// Each call spawns a fresh `claude -p` subprocess in stream-json mode,
/// writes a single user message (with image content blocks) to stdin,
/// and parses the streaming JSON output for text deltas. The interface
/// matches the previous Cloudflare-Worker-backed `ClaudeAPI` so the
/// CompanionManager does not need to know which backend is in use.
final class ClaudeAgentRunner {
    var model: String

    init(model: String = "claude-sonnet-4-6") {
        self.model = model
    }

    /// Stream a vision response from Claude using the locally installed CLI.
    /// Calls `onTextChunk` on the main actor with the accumulated text every
    /// time a new delta arrives, mirroring the previous SSE behavior.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        let claudeBinaryURL = try resolveClaudeBinaryPath()

        let userMessageJSONData = try buildUserMessageJSONData(
            images: images,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )

        let subprocess = Process()
        subprocess.executableURL = claudeBinaryURL
        subprocess.arguments = [
            "-p",
            "--model", model,
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--system-prompt", systemPrompt,
            "--permission-mode", "plan"
        ]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        subprocess.standardInput = stdinPipe
        subprocess.standardOutput = stdoutPipe
        subprocess.standardError = stderrPipe

        let payloadMegabytes = Double(userMessageJSONData.count) / 1_048_576.0
        print("🌐 Claude (local CLI) request: \(String(format: "%.1f", payloadMegabytes))MB, \(images.count) image(s), model \(model)")

        do {
            try subprocess.run()
        } catch {
            throw ClaudeAgentRunnerError.processFailedToStart(underlying: error)
        }

        // Send the user message on stdin and close so Claude knows the
        // input is complete. Without the close, `claude -p` keeps waiting.
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: userMessageJSONData)
            try stdinPipe.fileHandleForWriting.close()
        } catch {
            if subprocess.isRunning { subprocess.terminate() }
            throw ClaudeAgentRunnerError.unableToWriteInput(underlying: error)
        }

        let accumulatedResponseText = try await withTaskCancellationHandler {
            try await readStreamJSONOutput(
                from: stdoutPipe.fileHandleForReading,
                onTextChunk: onTextChunk
            )
        } onCancel: {
            if subprocess.isRunning { subprocess.terminate() }
        }

        subprocess.waitUntilExit()

        guard subprocess.terminationStatus == 0 else {
            let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
            let stderrText = String(data: stderrData ?? Data(), encoding: .utf8) ?? ""
            let stderrSnippet = String(stderrText.prefix(500))
            print("⚠️ Claude subprocess failed (exit \(subprocess.terminationStatus)): \(stderrSnippet)")
            throw ClaudeAgentRunnerError.processFailed(
                exitCode: subprocess.terminationStatus,
                stderrSnippet: stderrSnippet
            )
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, duration: duration)
    }

    // MARK: - Binary discovery

    /// Common install locations for the `claude` CLI on macOS, checked in
    /// order. The first executable file wins. Users with a non-standard
    /// install can override this by setting `ClaudeBinaryPath` in Info.plist.
    private static let commonClaudeBinaryPaths: [String] = [
        "~/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "~/.local/bin/claude",
        "~/.npm-global/bin/claude",
        "/usr/bin/claude"
    ]

    private func resolveClaudeBinaryPath() throws -> URL {
        if let configuredPathString = AppBundleConfiguration.stringValue(forKey: "ClaudeBinaryPath") {
            let expandedConfiguredPath = (configuredPathString as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expandedConfiguredPath) {
                return URL(fileURLWithPath: expandedConfiguredPath)
            }
        }

        for candidatePathString in Self.commonClaudeBinaryPaths {
            let expandedCandidatePath = (candidatePathString as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expandedCandidatePath) {
                return URL(fileURLWithPath: expandedCandidatePath)
            }
        }

        // Last resort: ask the user's login shell where `claude` lives.
        // Catches installs in non-standard locations (nvm, asdf, mise, etc.).
        if let shellResolvedPath = lookupClaudeViaLoginShell() {
            return URL(fileURLWithPath: shellResolvedPath)
        }

        throw ClaudeAgentRunnerError.claudeBinaryNotFound(
            searchedPaths: Self.commonClaudeBinaryPaths
        )
    }

    private func lookupClaudeViaLoginShell() -> String? {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellProcess = Process()
        shellProcess.executableURL = URL(fileURLWithPath: shellPath)
        shellProcess.arguments = ["-l", "-c", "command -v claude"]

        let shellStdoutPipe = Pipe()
        shellProcess.standardOutput = shellStdoutPipe
        shellProcess.standardError = Pipe()

        do {
            try shellProcess.run()
            shellProcess.waitUntilExit()
        } catch {
            return nil
        }

        guard shellProcess.terminationStatus == 0,
              let shellStdoutData = (try? shellStdoutPipe.fileHandleForReading.readToEnd()) ?? nil,
              let shellStdoutText = String(data: shellStdoutData, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !shellStdoutText.isEmpty,
              FileManager.default.isExecutableFile(atPath: shellStdoutText) else {
            return nil
        }

        return shellStdoutText
    }

    // MARK: - Input construction

    /// Builds a single newline-terminated JSON line for Claude Code's
    /// `--input-format stream-json` mode. The shape mirrors what was sent
    /// to the Anthropic Messages API previously: a user turn with image
    /// content blocks followed by a text block carrying the prompt.
    private func buildUserMessageJSONData(
        images: [(data: Data, label: String)],
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) throws -> Data {
        var userContentBlocks: [[String: Any]] = []

        for image in images {
            userContentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            userContentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }

        let historyAndPromptText = composeHistoryAndPromptText(
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )
        userContentBlocks.append([
            "type": "text",
            "text": historyAndPromptText
        ])

        let userMessageEnvelope: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": userContentBlocks
            ]
        ]

        var serializedJSONData = try JSONSerialization.data(
            withJSONObject: userMessageEnvelope,
            options: []
        )
        // stream-json input is newline-delimited; the trailing newline signals
        // that the message is complete before we close stdin.
        serializedJSONData.append(0x0A) // '\n'
        return serializedJSONData
    }

    /// Inlines the prior conversation turns into the new user message as
    /// plain text. Claude Code's stream-json input does accept replayed
    /// assistant messages, but mixing them with image attachments is
    /// brittle in some CLI versions — embedding as text is the safe path.
    private func composeHistoryAndPromptText(
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) -> String {
        if conversationHistory.isEmpty {
            return userPrompt
        }

        var composedLines: [String] = []
        composedLines.append("Previous conversation (for your context):")
        for (previousUserText, previousAssistantText) in conversationHistory {
            composedLines.append("User: \(previousUserText)")
            composedLines.append("Assistant: \(previousAssistantText)")
        }
        composedLines.append("")
        composedLines.append("User question: \(userPrompt)")
        return composedLines.joined(separator: "\n")
    }

    private func detectImageMediaType(for imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngSignatureBytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourImageBytes = [UInt8](imageData.prefix(4))
            if firstFourImageBytes == pngSignatureBytes {
                return "image/png"
            }
        }
        return "image/jpeg"
    }

    // MARK: - Output parsing

    /// Reads Claude Code's newline-delimited JSON output and pulls the
    /// streaming `text_delta` chunks out of the `stream_event` envelopes.
    /// Each delta is appended to the running text and forwarded to the
    /// caller's `onTextChunk` so the UI can render progressively.
    private func readStreamJSONOutput(
        from outputFileHandle: FileHandle,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        var accumulatedResponseText = ""

        for try await outputLine in outputFileHandle.bytes.lines {
            guard !outputLine.isEmpty,
                  let outputLineData = outputLine.data(using: .utf8),
                  let parsedEvent = try? JSONSerialization.jsonObject(with: outputLineData) as? [String: Any] else {
                continue
            }

            guard let eventType = parsedEvent["type"] as? String else { continue }

            // With --include-partial-messages, Claude Code emits the raw
            // Anthropic SSE events wrapped in a "stream_event" envelope.
            // We care about content_block_delta → text_delta.
            if eventType == "stream_event",
               let innerEvent = parsedEvent["event"] as? [String: Any],
               let innerEventType = innerEvent["type"] as? String,
               innerEventType == "content_block_delta",
               let contentDelta = innerEvent["delta"] as? [String: Any],
               let contentDeltaType = contentDelta["type"] as? String,
               contentDeltaType == "text_delta",
               let textChunk = contentDelta["text"] as? String {
                accumulatedResponseText += textChunk
                let currentAccumulatedText = accumulatedResponseText
                await onTextChunk(currentAccumulatedText)
            }
        }

        return accumulatedResponseText
    }
}
