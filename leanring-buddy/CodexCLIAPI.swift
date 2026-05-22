//
//  CodexCLIAPI.swift
//  Local Codex CLI integration
//

import Foundation

/// Runs the local Codex CLI so Clicky can use the user's existing Codex login
/// instead of requiring an OpenAI API key in the Worker.
class CodexCLIAPI {
    var model: String

    init(model: String = "gpt-5.2-codex") {
        self.model = model
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()
        let responseText = try await runCodexCLI(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )
        await onTextChunk(responseText)
        return (text: responseText, duration: Date().timeIntervalSince(startTime))
    }

    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()
        let responseText = try await runCodexCLI(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )
        return (text: responseText, duration: Date().timeIntervalSince(startTime))
    }

    private func runCodexCLI(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) async throws -> String {
        let selectedModel = model
        return try await Task.detached(priority: .userInitiated) {
            let temporaryDirectory = try Self.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

            let imageFileURLs = try Self.writeImages(images, to: temporaryDirectory)
            let outputFileURL = temporaryDirectory.appendingPathComponent("codex-response.txt")
            let prompt = Self.makePrompt(
                images: images,
                systemPrompt: systemPrompt,
                conversationHistory: conversationHistory,
                userPrompt: userPrompt
            )

            var arguments = [
                "exec",
                "--skip-git-repo-check",
                "--ephemeral",
                "--sandbox", "read-only",
                "--cd", temporaryDirectory.path,
                "--model", selectedModel,
                "--output-last-message", outputFileURL.path,
                "--color", "never"
            ]

            for imageFileURL in imageFileURLs {
                arguments.append("--image")
                arguments.append(imageFileURL.path)
            }

            arguments.append(prompt)

            let process = Process()
            process.executableURL = try Self.codexExecutableURL()
            process.arguments = arguments

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let standardOutput = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let standardError = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                throw NSError(
                    domain: "CodexCLIAPI",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: Self.makeFailureMessage(standardError: standardError, standardOutput: standardOutput)]
                )
            }

            if let responseText = try? String(contentsOf: outputFileURL, encoding: .utf8),
               !responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return responseText.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let fallbackText = standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fallbackText.isEmpty else {
                throw NSError(
                    domain: "CodexCLIAPI",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Codex CLI finished without a response"]
                )
            }

            return fallbackText
        }.value
    }

    private static func codexExecutableURL() throws -> URL {
        let candidatePaths = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ]

        for candidatePath in candidatePaths where FileManager.default.isExecutableFile(atPath: candidatePath) {
            return URL(fileURLWithPath: candidatePath)
        }

        throw NSError(
            domain: "CodexCLIAPI",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Codex CLI was not found. Install Codex CLI and run `codex login` before using the Codex provider."]
        )
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clicky-codex-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private static func writeImages(
        _ images: [(data: Data, label: String)],
        to directoryURL: URL
    ) throws -> [URL] {
        try images.enumerated().map { index, image in
            let fileExtension = detectImageFileExtension(for: image.data)
            let fileURL = directoryURL.appendingPathComponent("screen-\(index + 1).\(fileExtension)")
            try image.data.write(to: fileURL, options: .atomic)
            return fileURL
        }
    }

    private static func detectImageFileExtension(for imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "png"
            }
        }
        return "jpg"
    }

    private static func makePrompt(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) -> String {
        let imageLabels = images.map(\.label).joined(separator: "\n")
        let conversationContext = conversationHistory.isEmpty
            ? "None"
            : conversationHistory
                .map { "User: \($0.userPlaceholder)\nAssistant: \($0.assistantResponse)" }
                .joined(separator: "\n\n")

        return """
        You are running inside Clicky, a macOS cursor buddy. Do not inspect or modify local files. Do not run shell commands. Use only the attached screenshot images and this prompt.

        System instructions:
        \(systemPrompt)

        Attached screenshot labels:
        \(imageLabels)

        Recent conversation context:
        \(conversationContext)

        Current user request:
        \(userPrompt)
        """
    }

    private static func makeFailureMessage(standardError: String, standardOutput: String) -> String {
        let combinedOutput = [standardError, standardOutput]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        guard !combinedOutput.isEmpty else {
            return "Codex CLI failed. Run `codex doctor` and confirm `codex login` is complete."
        }

        return combinedOutput
    }
}
