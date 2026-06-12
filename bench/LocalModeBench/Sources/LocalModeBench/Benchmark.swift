//
//  Benchmark.swift
//  LocalModeBench
//
//  Measures first-token latency and decode speed for the exact model and
//  parameters Clicky's Local Mode uses. Run it on the machine you're
//  quoting numbers for. Build with Xcode (SwiftPM CLI can't compile MLX's
//  Metal shaders):
//
//    xcodebuild -scheme LocalModeBench -destination 'platform=macOS' \
//      -derivedDataPath /tmp/bench-dd -skipMacroValidation build
//    /tmp/bench-dd/Build/Products/Debug/LocalModeBench
//

import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

@main
struct LocalModeBench {
    // Keep in sync with CompanionManager's local mode system prompt — the
    // prompt length affects prefill time, which dominates first-token latency.
    static let localVoiceSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk. you're running fully on their mac right now — no cloud, no screen access — so answer from what they said and what you remember of this conversation. your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk.

    rules:
    - default to one or two sentences. be direct and dense. if the user asks you to go deeper, give a longer explanation.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - you can't see the screen in local mode. if the user asks about something on their screen, say so plainly and ask them to read or describe it — or suggest flipping to a cloud model for screen questions.
    - never say "simply" or "just".
    - never output coordinate tags like [POINT:...] — you can't point at the screen in local mode.
    """

    static let voiceStyleQuestions = [
        "what does git rebase actually do?",
        "what's the difference between a thread and a process?",
        "give me a quick dinner idea with eggs and rice",
    ]

    static func main() async throws {
        // Same directory LocalChatProvider uses, so running the bench also
        // pre-warms the app's model cache (and vice versa).
        let modelCacheDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Clicky/models/huggingface", isDirectory: true)
        let hubClient = HubClient(cache: HubCache(cacheDirectory: modelCacheDirectory))

        print("loading mlx-community/Llama-3.2-3B-Instruct-4bit (downloads ~1.8 GB on first run)...")
        let loadStartDate = Date()
        let modelContainer = try await LLMModelFactory.shared.loadContainer(
            from: #hubDownloader(hubClient),
            using: #huggingFaceTokenizerLoader(),
            configuration: LLMRegistry.llama3_2_3B_4bit,
            progressHandler: { downloadProgress in
                print(String(format: "download: %3.0f%%", downloadProgress.fractionCompleted * 100))
            }
        )
        print(String(format: "model ready in %.1fs", Date().timeIntervalSince(loadStartDate)))

        // Same parameters as LocalChatProvider.localGenerateParameters.
        let generateParameters = GenerateParameters(
            maxTokens: 1024,
            maxKVSize: 4096,
            temperature: 0.7
        )

        for (questionIndex, question) in voiceStyleQuestions.enumerated() {
            let requestStartDate = Date()
            var firstTokenLatencySeconds: TimeInterval?
            var reportedTokensPerSecond: Double = 0
            var responseText = ""

            let languageModelInput = try await modelContainer.prepare(
                input: UserInput(chat: [
                    .system(localVoiceSystemPrompt),
                    .user(question),
                ])
            )
            let generationStream = try await modelContainer.generate(
                input: languageModelInput,
                parameters: generateParameters
            )

            for await generation in generationStream {
                switch generation {
                case .chunk(let textChunk):
                    if firstTokenLatencySeconds == nil {
                        firstTokenLatencySeconds = Date().timeIntervalSince(requestStartDate)
                    }
                    responseText += textChunk
                case .info(let completionInfo):
                    reportedTokensPerSecond = completionInfo.tokensPerSecond
                case .toolCall:
                    break
                }
            }

            let totalDurationSeconds = Date().timeIntervalSince(requestStartDate)
            print(String(
                format: "q%d: first token %.2fs | %.1f tok/s | total %.1fs | %d chars",
                questionIndex + 1,
                firstTokenLatencySeconds ?? -1,
                reportedTokensPerSecond,
                totalDurationSeconds,
                responseText.count
            ))
            print("   \"\(responseText.prefix(120))\(responseText.count > 120 ? "…" : "")\"")
        }
    }
}
