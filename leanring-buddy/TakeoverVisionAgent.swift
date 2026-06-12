//
//  TakeoverVisionAgent.swift
//  leanring-buddy
//
//  The brain for offline takeover: a local vision-language model (Qwen2.5-VL-3B
//  via MLX) that looks at one screenshot plus the task and recent history and
//  emits exactly one JSON action. No native tool-use API — the controller
//  parses, guards, and executes what this returns.
//
//  Honest reality: small local VLMs misground on dense/high-res screens. This
//  is why takeover defaults to dry-run and is scoped to simple, low-density UIs.
//

import Combine
import CoreImage
import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers

@MainActor
final class TakeoverVisionAgent: ObservableObject {
    /// Swap to "mlx-community/Holo1-3B-4bit" (a Qwen2.5-VL-3B UI-grounding
    /// finetune) for better click accuracy — it would need a Click(x,y)
    /// parser instead of the JSON one. Qwen2.5-VL-3B is the proven registry
    /// default and emits the JSON schema fine.
    private static let modelConfiguration = VLMRegistry.qwen2_5VL3BInstruct4Bit

    enum Readiness: Equatable {
        case notLoaded
        case downloading(progressFraction: Double)
        case loading
        case ready
        case failed(errorDescription: String)
    }

    @Published private(set) var readiness: Readiness = .notLoaded

    private var loadedModelContainer: ModelContainer?
    private var modelLoadTask: Task<ModelContainer, Error>?

    private static func modelCacheDirectory() throws -> URL {
        let applicationSupportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return applicationSupportDirectory
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
    }

    @discardableResult
    func loadModelIfNeeded() -> Task<ModelContainer, Error> {
        if let modelLoadTask { return modelLoadTask }
        let newTask = Task<ModelContainer, Error> {
            do {
                let container = try await loadModelContainer()
                loadedModelContainer = container
                readiness = .ready
                return container
            } catch {
                modelLoadTask = nil
                readiness = .failed(errorDescription: error.localizedDescription)
                throw error
            }
        }
        modelLoadTask = newTask
        return newTask
    }

    private func loadModelContainer() async throws -> ModelContainer {
        // Bound MLX's buffer cache before a long multi-step loop — unbounded
        // KV/cache growth is the main per-step OOM risk on 16 GB.
        MLX.Memory.cacheLimit = 32 * 1024 * 1024

        readiness = .downloading(progressFraction: 0)
        let hubClient = HubClient(cache: HubCache(cacheDirectory: try Self.modelCacheDirectory()))
        print("👁️ Takeover VLM: loading \(Self.modelConfiguration.name)")

        let container = try await VLMModelFactory.shared.loadContainer(
            from: #hubDownloader(hubClient),
            using: #huggingFaceTokenizerLoader(),
            configuration: Self.modelConfiguration,
            progressHandler: { downloadProgress in
                let fraction = downloadProgress.fractionCompleted
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.readiness else { return }
                    self.readiness = .downloading(progressFraction: fraction)
                }
            }
        )
        readiness = .loading
        return container
    }

    // MARK: - Prompt

    private static let systemPrompt = """
    you control a mac by looking at one screenshot and choosing ONE action.
    output EXACTLY ONE json object and NOTHING else — no prose, no markdown, no second action.
    all coordinates are integer pixels in the screenshot, origin top-left (0,0 = top-left corner).

    allowed actions (pick one):
    {"action":"click","x":N,"y":N,"target_label":"short name of the thing","why":"one short clause"}
    {"action":"type","text":"literal text","why":"..."}
    {"action":"key","combo":"return | esc | cmd+s | ...","why":"..."}
    {"action":"scroll","x":N,"y":N,"dir":"up|down|left|right","amount":1-5,"why":"..."}
    {"action":"done","summary":"what you accomplished"}
    {"action":"give_up","reason":"why you cannot continue"}

    rules:
    - one action per turn. the screen will update and you'll get a new screenshot.
    - typing NEVER presses enter; use a key action with "return" to submit.
    - click the CENTER of the target. if you're unsure where something is, give_up instead of guessing.
    - when the goal is clearly already done on screen, output done.
    - keep target_label and why to a few words.
    """

    /// Asks the model for the next action given the current screen.
    func decideNextAction(
        task: String,
        historyTrace: [String],
        screenshotJPEG: Data,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int
    ) async throws -> TakeoverAction {
        let container: ModelContainer
        if let loadedModelContainer {
            container = loadedModelContainer
        } else {
            container = try await loadModelIfNeeded().value
        }

        guard let screenshotImage = CIImage(data: screenshotJPEG) else {
            throw NSError(domain: "TakeoverVisionAgent", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "couldn't read the screenshot"])
        }

        // Text BEFORE the image improves click accuracy (Anthropic computer-use tip).
        var userText = "TASK: \(task)\n"
        if !historyTrace.isEmpty {
            userText += "SO FAR:\n" + historyTrace.suffix(8).enumerated()
                .map { "  step\($0.offset + 1): \($0.element)" }.joined(separator: "\n") + "\n"
        }
        userText += "The screenshot below is \(screenshotWidthInPixels)x\(screenshotHeightInPixels) pixels. Choose one action."

        let userInput = UserInput(chat: [
            .system(Self.systemPrompt),
            .user(userText, images: [.ciImage(screenshotImage)]),
        ])

        let languageModelInput = try await container.prepare(input: userInput)
        // Tight token budget — the model only needs to emit one short JSON object.
        let generationStream = try await container.generate(
            input: languageModelInput,
            parameters: GenerateParameters(maxTokens: 200, temperature: 0.2)
        )

        var rawOutput = ""
        for await generation in generationStream {
            if Task.isCancelled { break }
            if case .chunk(let textChunk) = generation { rawOutput += textChunk }
        }
        try Task.checkCancellation()

        print("👁️ Takeover VLM raw: \(rawOutput.prefix(200))")
        return try TakeoverActionParser.parse(rawOutput)
    }
}
