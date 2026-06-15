//
//  LocalChatProvider.swift
//  leanring-buddy
//
//  On-device chat provider for Local Mode, backed by MLX. Runs
//  Llama-3.2-3B-Instruct (4-bit, ~1.8 GB) entirely on the Mac's GPU —
//  no network, no screenshots, nothing leaves the machine.
//
//  The model downloads once from Hugging Face into Application Support
//  with visible progress, then loads straight from disk on every later
//  launch (so Local Mode works with wifi off after the first download).
//

import Combine
import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

@MainActor
final class LocalChatProvider: BuddyChatProvider, ObservableObject {
    /// Sentinel stored in the same UserDefaults slot as the Claude model IDs.
    /// CompanionManager routes to this provider whenever selectedModel
    /// equals this value — the string never reaches the Anthropic API.
    static let modelPickerID = "local"

    /// The one supported local model. A registry constant, 4-bit quantized,
    /// small enough for a 16 GB machine with plenty of room to breathe.
    private static let modelConfiguration = LLMRegistry.llama3_2_3B_4bit

    let displayName = "local"

    /// Where the local model lives on the panel UI's terms. The panel shows
    /// a progress bar during .downloading and an error + retry on .failed.
    enum ModelReadiness: Equatable {
        case notDownloaded
        case downloading(progressFraction: Double)
        case loading
        case ready
        case failed(errorDescription: String)
    }

    @Published private(set) var modelReadiness: ModelReadiness = .notDownloaded

    /// The loaded model, kept in memory for the life of the app so responses
    /// after the first don't pay the load cost again.
    private var loadedModelContainer: ModelContainer?

    /// In-flight load, shared so a double-tap on the picker doesn't kick off
    /// two downloads.
    private var modelLoadTask: Task<ModelContainer, Error>?

    /// UserDefaults key holding the on-disk directory of the downloaded model.
    /// When this directory exists we load straight from disk — no network,
    /// which is what makes Local Mode work offline across relaunches.
    private static let downloadedModelDirectoryDefaultsKey = "localModelDownloadedDirectory"

    init() {
        // If the model was downloaded on an earlier launch, report it as
        // ready-to-load rather than not-downloaded so the picker doesn't
        // threaten the user with another 1.8 GB download.
        if Self.previouslyDownloadedModelDirectory() != nil {
            modelReadiness = .loading
        }
    }

    /// The model directory from a previous successful download, if it still
    /// exists on disk.
    private static func previouslyDownloadedModelDirectory() -> URL? {
        guard let storedPath = UserDefaults.standard.string(forKey: downloadedModelDirectoryDefaultsKey) else {
            return nil
        }
        let storedDirectoryURL = URL(fileURLWithPath: storedPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: storedDirectoryURL.path) else {
            return nil
        }
        return storedDirectoryURL
    }

    /// Kicks off (or joins) the download + load. Safe to call repeatedly —
    /// the picker calls this every time "Local" is selected.
    @discardableResult
    func loadModelIfNeeded() -> Task<ModelContainer, Error> {
        if let modelLoadTask {
            return modelLoadTask
        }

        let newModelLoadTask = Task<ModelContainer, Error> {
            do {
                let modelContainer = try await loadModelContainer()
                loadedModelContainer = modelContainer
                modelReadiness = .ready
                return modelContainer
            } catch {
                // Clear the task so a retry actually retries instead of
                // re-awaiting the failed task.
                modelLoadTask = nil
                modelReadiness = .failed(errorDescription: error.localizedDescription)
                throw error
            }
        }
        modelLoadTask = newModelLoadTask
        return newModelLoadTask
    }

    private func loadModelContainer() async throws -> ModelContainer {
        // Fast path: the model is already on disk from a previous launch.
        // Loads with zero network — this is what keeps Local Mode working
        // when the machine is offline.
        if let downloadedModelDirectory = Self.previouslyDownloadedModelDirectory() {
            modelReadiness = .loading
            print("🏠 Local model: loading from disk at \(downloadedModelDirectory.path)")
            return try await LLMModelFactory.shared.loadContainer(
                from: downloadedModelDirectory,
                using: #huggingFaceTokenizerLoader()
            )
        }

        // First time: download from Hugging Face with visible progress.
        modelReadiness = .downloading(progressFraction: 0)
        let hubCacheDirectory = try ClickyModelCache.huggingFaceCacheDirectory()
        let hubClient = HubClient(cache: HubCache(cacheDirectory: hubCacheDirectory))
        print("🏠 Local model: downloading \(Self.modelConfiguration.name) to \(hubCacheDirectory.path)")

        let modelContainer = try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(hubClient),
            using: #huggingFaceTokenizerLoader(),
            configuration: Self.modelConfiguration,
            progressHandler: { downloadProgress in
                let progressFraction = downloadProgress.fractionCompleted
                Task { @MainActor [weak self] in
                    // The handler also fires during post-download loading;
                    // don't regress the state once loading has started.
                    guard let self, case .downloading = self.modelReadiness else { return }
                    self.modelReadiness = .downloading(progressFraction: progressFraction)
                }
            }
        )

        modelReadiness = .loading

        // Remember where the weights landed so future launches load from
        // disk directly (and offline).
        let modelDirectory = try await modelContainer.modelDirectory
        UserDefaults.standard.set(modelDirectory.path, forKey: Self.downloadedModelDirectoryDefaultsKey)
        print("🏠 Local model: downloaded to \(modelDirectory.path)")

        return modelContainer
    }

    // MARK: - Generation

    /// Capped to match the cloud path's max_tokens (1024) and a bounded KV
    /// window so memory stays flat over a long session.
    private static let localGenerateParameters = GenerateParameters(
        maxTokens: 1024,
        maxKVSize: 4096,
        temperature: 0.7
    )

    func generateStreamingResponse(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userTranscript: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> BuddyChatResponse {
        // `images` is intentionally ignored: in Local Mode the screenshot is
        // never captured, so there is nothing to attach by construction.
        let modelContainer: ModelContainer
        if let loadedModelContainer {
            modelContainer = loadedModelContainer
        } else {
            modelContainer = try await loadModelIfNeeded().value
        }

        let requestStartDate = Date()

        var chatMessages: [Chat.Message] = [.system(systemPrompt)]
        for exchange in conversationHistory {
            chatMessages.append(.user(exchange.userTranscript))
            chatMessages.append(.assistant(exchange.assistantResponse))
        }
        chatMessages.append(.user(userPrompt))

        let languageModelInput = try await modelContainer.prepare(input: UserInput(chat: chatMessages))
        let generationStream = try await modelContainer.generate(
            input: languageModelInput,
            parameters: Self.localGenerateParameters
        )

        var accumulatedResponseText = ""
        var firstChunkDate: Date?
        var reportedTokensPerSecond: Double?

        for await generation in generationStream {
            // The user pressed the hotkey again — stop consuming; dropping
            // the stream tears down the underlying generation.
            if Task.isCancelled { break }

            switch generation {
            case .chunk(let textChunk):
                if firstChunkDate == nil {
                    firstChunkDate = Date()
                }
                accumulatedResponseText += textChunk
                onTextChunk(accumulatedResponseText)
            case .info(let completionInfo):
                reportedTokensPerSecond = completionInfo.tokensPerSecond
            case .toolCall:
                // The local prompt defines no tools; nothing to do.
                break
            }
        }

        try Task.checkCancellation()

        let totalDurationSeconds = Date().timeIntervalSince(requestStartDate)
        let firstTokenLatencySeconds = firstChunkDate
            .map { firstChunkDate in firstChunkDate.timeIntervalSince(requestStartDate) }

        if let reportedTokensPerSecond {
            let firstTokenDescription = firstTokenLatencySeconds
                .map { String(format: "%.2fs", $0) } ?? "n/a"
            print("🏠 Local generation: first token \(firstTokenDescription), \(String(format: "%.1f", reportedTokensPerSecond)) tok/s, \(String(format: "%.1fs", totalDurationSeconds)) total")
        }

        return BuddyChatResponse(
            text: accumulatedResponseText.trimmingCharacters(in: .whitespacesAndNewlines),
            firstTokenLatencySeconds: firstTokenLatencySeconds,
            totalDurationSeconds: totalDurationSeconds,
            tokensPerSecond: reportedTokensPerSecond
        )
    }
}
