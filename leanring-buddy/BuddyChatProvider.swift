//
//  BuddyChatProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for chat response backends — the same pattern
//  BuddyTranscriptionProvider uses for voice transcription. The cloud
//  provider wraps the existing ClaudeAPI (via the Cloudflare Worker proxy);
//  the local provider runs an on-device model via MLX.
//

import Foundation

/// The result of one fully-streamed chat response.
struct BuddyChatResponse {
    /// The complete response text after the stream finished.
    let text: String
    /// Seconds from sending the request to the first streamed text chunk
    /// arriving. This is the number the latency badge shows, because it's
    /// the part of the wait the user actually feels.
    let firstTokenLatencySeconds: TimeInterval?
    /// Seconds from sending the request to the end of the stream.
    let totalDurationSeconds: TimeInterval
    /// Decode speed reported by the engine, if it reports one. Local
    /// inference fills this in; the cloud path has no equivalent signal.
    let tokensPerSecond: Double?
}

@MainActor
protocol BuddyChatProvider: AnyObject {
    /// Short lowercase name for logs and the latency badge ("cloud", "local").
    var displayName: String { get }

    /// Sends one chat turn and streams the response back. `onTextChunk`
    /// receives the accumulated text so far (not the delta) on the main
    /// actor each time new text arrives — the same ergonomics ClaudeAPI
    /// already uses, so call sites don't change shape.
    func generateStreamingResponse(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userTranscript: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> BuddyChatResponse
}

/// Cloud chat provider — a thin wrapper around the existing ClaudeAPI so the
/// Sonnet/Opus request path behaves exactly as it did before the provider
/// seam existed. The only addition is first-token timing, measured out here
/// so ClaudeAPI itself stays untouched.
@MainActor
final class CloudChatProvider: BuddyChatProvider {
    let displayName = "cloud"

    private let claudeAPI: ClaudeAPI

    /// The Claude model ID sent with each request (e.g. "claude-sonnet-4-6").
    var model: String {
        get { claudeAPI.model }
        set { claudeAPI.model = newValue }
    }

    init(claudeAPI: ClaudeAPI) {
        self.claudeAPI = claudeAPI
    }

    func generateStreamingResponse(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userTranscript: String, assistantResponse: String)],
        userPrompt: String,
        onTextChunk: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> BuddyChatResponse {
        let requestStartDate = Date()
        let firstChunkRecorder = BuddyFirstChunkRecorder()

        // ClaudeAPI's history tuple labels predate the provider seam —
        // map ours onto them rather than touching the working client.
        let historyForClaudeAPI = conversationHistory.map { exchange in
            (userPlaceholder: exchange.userTranscript, assistantResponse: exchange.assistantResponse)
        }

        let (fullResponseText, totalDurationSeconds) = try await claudeAPI.analyzeImageStreaming(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: historyForClaudeAPI,
            userPrompt: userPrompt,
            onTextChunk: { accumulatedText in
                if firstChunkRecorder.firstChunkDate == nil {
                    firstChunkRecorder.firstChunkDate = Date()
                }
                onTextChunk(accumulatedText)
            }
        )

        let firstTokenLatencySeconds = firstChunkRecorder.firstChunkDate
            .map { firstChunkDate in firstChunkDate.timeIntervalSince(requestStartDate) }

        return BuddyChatResponse(
            text: fullResponseText,
            firstTokenLatencySeconds: firstTokenLatencySeconds,
            totalDurationSeconds: totalDurationSeconds,
            tokensPerSecond: nil
        )
    }
}

/// Tiny main-actor box so a streaming closure can record when the first
/// chunk arrived without tripping concurrency checks.
@MainActor
final class BuddyFirstChunkRecorder {
    var firstChunkDate: Date?
}
