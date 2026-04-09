//
//  LocalMLXVLMClient.swift
//  leanring-buddy
//
//  Created by MD Sahil AK on 09/04/26.
//

import CoreImage
import Foundation
@preconcurrency import Hub
import MLX
import MLXLMCommon
import MLXVLM

protocol CompanionChatClient: AnyObject {
    func prepareSelectedModel(
        progressHandler: @MainActor @escaping (Progress?) -> Void
    ) async throws

    func offloadResources()

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        progressHandler: @MainActor @escaping (Progress?) -> Void,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval)
}

final class LocalMLXVLMClient: CompanionChatClient {
    static let fixedModelDisplayName = "Qwen 3 VL 4B"

    private let fixedModelIdentifier = "qwen3-vl-4b"
    private let fixedModelConfiguration = VLMRegistry.qwen3VL4BInstruct4Bit
    private let modelCache = NSCache<NSString, ModelContainer>()
    private let stateLock = NSLock()
    private var inFlightLoadTask: Task<ModelContainer, Error>?
    private var hasWarmedFixedModel = false
    private let hub: HubApi

    init() {
        let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        let modelDownloadDirectory = applicationSupportDirectory
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: modelDownloadDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        self.hub = HubApi(downloadBase: modelDownloadDirectory)
    }

    func prepareSelectedModel(
        progressHandler: @MainActor @escaping (Progress?) -> Void
    ) async throws {
        let modelContainer = try await loadModelContainer(progressHandler: progressHandler)
        let hasAlreadyWarmedModel = stateLock.withLock { hasWarmedFixedModel }

        guard !hasAlreadyWarmedModel else { return }

        let warmupImage = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))

        let warmupMessages: [Chat.Message] = [
            .system("you are clicky, a concise local desktop assistant."),
            .user("reply with one word.", images: [.ciImage(warmupImage)])
        ]

        let warmupInput = UserInput(
            chat: warmupMessages,
            processing: .init(resize: CGSize(width: 768, height: 768))
        )

        _ = try await modelContainer.perform { context in
            let preparedInput = try await context.processor.prepare(input: warmupInput)
            let generationStream = try MLXLMCommon.generate(
                input: preparedInput,
                parameters: GenerateParameters(maxTokens: 1, temperature: 0),
                context: context
            )

            for await _ in generationStream {
                if Task.isCancelled {
                    break
                }
            }
        }

        stateLock.withLock {
            hasWarmedFixedModel = true
        }
    }

    func offloadResources() {
        stateLock.withLock {
            inFlightLoadTask?.cancel()
            inFlightLoadTask = nil
            hasWarmedFixedModel = false
        }
        modelCache.removeAllObjects()
        // Force MLX to release cached buffers as aggressively as possible while
        // Claude mode is active, then restore a working cache limit on next load.
        MLX.GPU.set(cacheLimit: 0)
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        progressHandler: @MainActor @escaping (Progress?) -> Void,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let modelContainer = try await loadModelContainer(progressHandler: progressHandler)

        let startTime = Date()

        let chatMessages = try buildChatMessages(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt
        )

        let userInput = UserInput(
            chat: chatMessages,
            processing: .init(resize: CGSize(width: 1024, height: 1024))
        )

        var accumulatedResponseText = ""

        let generationStream = try await modelContainer.perform { context in
            let preparedInput = try await context.processor.prepare(input: userInput)

            return try MLXLMCommon.generate(
                input: preparedInput,
                parameters: GenerateParameters(maxTokens: 1024),
                context: context
            )
        }

        for await generation in generationStream {
            if Task.isCancelled {
                break
            }

            switch generation {
            case .chunk(let textChunk):
                accumulatedResponseText += textChunk
                let currentAccumulatedText = accumulatedResponseText
                await MainActor.run {
                    onTextChunk(currentAccumulatedText)
                }
            case .info:
                break
            case .toolCall:
                break
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText.trimmingCharacters(in: .whitespacesAndNewlines), duration: duration)
    }

    private func buildChatMessages(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String
    ) throws -> [Chat.Message] {
        var chatMessages: [Chat.Message] = [
            .system(systemPrompt)
        ]

        for historyEntry in conversationHistory {
            chatMessages.append(.user(historyEntry.userPlaceholder))
            chatMessages.append(.assistant(historyEntry.assistantResponse))
        }

        let imageInputs = try images.map { image in
            guard let ciImage = CIImage(data: image.data) else {
                throw NSError(
                    domain: "LocalMLXVLMClient",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to decode screenshot data for local model input."]
                )
            }
            return UserInput.Image.ciImage(ciImage)
        }

        let currentUserMessageContent = buildClaudeEquivalentUserMessageContent(
            images: images,
            userPrompt: userPrompt
        )

        chatMessages.append(.user(currentUserMessageContent, images: imageInputs))
        return chatMessages
    }

    private func buildClaudeEquivalentUserMessageContent(
        images: [(data: Data, label: String)],
        userPrompt: String
    ) -> String {
        let orderedImageLabels = images.map(\.label).joined(separator: "\n")

        guard !orderedImageLabels.isEmpty else {
            return userPrompt
        }

        return """
        attached image labels, in the same order as the screenshots:
        \(orderedImageLabels)

        \(userPrompt)
        """
    }

    private func loadModelContainer(
        progressHandler: @MainActor @escaping (Progress?) -> Void
    ) async throws -> ModelContainer {
        if let cachedModelContainer = modelCache.object(forKey: fixedModelIdentifier as NSString) {
            await MainActor.run {
                progressHandler(nil)
            }
            return cachedModelContainer
        }

        let loadTask: Task<ModelContainer, Error> = stateLock.withLock {
            if let existingTask = inFlightLoadTask {
                return existingTask
            }

            let newTask = Task { [hub] in
                MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)

                let modelContainer = try await VLMModelFactory.shared.loadContainer(
                    hub: hub,
                    configuration: fixedModelConfiguration
                ) { progress in
                    Task { @MainActor in
                        progressHandler(progress)
                    }
                }

                return modelContainer
            }

            inFlightLoadTask = newTask
            return newTask
        }

        do {
            let modelContainer = try await loadTask.value
            stateLock.withLock {
                inFlightLoadTask = nil
            }
            modelCache.setObject(modelContainer, forKey: fixedModelIdentifier as NSString)
            await MainActor.run {
                progressHandler(nil)
            }
            return modelContainer
        } catch {
            stateLock.withLock {
                inFlightLoadTask = nil
            }
            await MainActor.run {
                progressHandler(nil)
            }
            throw error
        }
    }
}

private extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
