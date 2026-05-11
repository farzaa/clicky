//
//  AgentTaskPlanner.swift
//  leanring-buddy
//
//  Turns a raw voice transcript into either a structured `AgentTaskBrief`
//  (for background tasks) or a signal to fall through to the inline
//  voice-response loop (for short conversational requests). Uses Anthropic
//  via the vibe-id proxy with a small classifier prompt.
//

import Foundation

/// Outcome of running the planner over a transcript.
enum AgentTaskPlannerDecision {
    /// The transcript should run through the existing inline tool-use loop.
    case routeToInline
    /// The transcript is a substantial background task. Caller should hand
    /// the brief to `AgentTaskManager.startTask(brief:)`.
    case routeToBackground(brief: AgentTaskBrief)
}

struct AgentTaskPlanner {

    /// Base URL for the vibe-id /chat endpoint. Same surface the existing
    /// ClaudeAPI uses — wraps Anthropic's Messages API with auth + quota.
    private let proxyChatEndpointURL: URL
    private let urlSession: URLSession

    /// Model used by the planner. Defaults to the same Sonnet model the
    /// inline loop uses — fast enough for ~500-token outputs, smart enough
    /// to write a real brief.
    let model: String

    init(
        proxyChatEndpointURL: URL,
        urlSession: URLSession = .shared,
        model: String = "claude-sonnet-4-6"
    ) {
        self.proxyChatEndpointURL = proxyChatEndpointURL
        self.urlSession = urlSession
        self.model = model
    }

    /// Classifies the transcript and, if it's a background task, expands it
    /// into a structured brief. Throws on network / parsing failures so the
    /// caller can fall through to inline as a safe default.
    func classifyAndPlan(transcript: String) async throws -> AgentTaskPlannerDecision {

        let plannerSystemPrompt = Self.plannerSystemPrompt
        let plannerUserPrompt = Self.buildPlannerUserPrompt(transcript: transcript)

        var apiRequest = URLRequest(url: proxyChatEndpointURL)
        apiRequest.httpMethod = "POST"
        apiRequest.timeoutInterval = 30
        apiRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let installToken = DotInstallTokenStore.currentInstallToken() {
            apiRequest.setValue("Bearer \(installToken)", forHTTPHeaderField: "Authorization")
        }

        let requestBody: [String: Any] = [
            "model": model,
            "max_tokens": 700,
            "system": plannerSystemPrompt,
            "messages": [
                ["role": "user", "content": plannerUserPrompt]
            ]
        ]
        apiRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (responseData, urlResponse) = try await urlSession.data(for: apiRequest)
        guard let httpResponse = urlResponse as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseBodyText = String(data: responseData, encoding: .utf8) ?? "<no body>"
            throw AgentTaskPlannerError.httpFailure(
                statusCode: (urlResponse as? HTTPURLResponse)?.statusCode ?? -1,
                bodyText: responseBodyText
            )
        }

        guard let parsedJSON = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let contentArray = parsedJSON["content"] as? [[String: Any]],
              let textBlock = contentArray.first(where: { ($0["type"] as? String) == "text" }),
              let plannerOutputText = textBlock["text"] as? String else {
            throw AgentTaskPlannerError.responseFormatInvalid
        }

        return try Self.parsePlannerOutput(
            plannerOutputText: plannerOutputText,
            userOriginalRequest: transcript
        )
    }

    // MARK: - Prompt assembly

    private static let plannerSystemPrompt: String = """
    You are the planner for Dot, a macOS voice companion. The user just said something into push-to-talk. You decide whether the request is a short conversational/voice command (handle inline — the user wants a quick response) or a substantial background coding/research/build task (hand off to Claude Code, which will run for minutes in the background).

    INLINE means: questions, where-is-X, how-do-I-X, "open the calendar", "play the next song", "click the save button", chat, lookups, anything that resolves in under a minute of direct response.

    BACKGROUND means: build an app, reimplement a paper, scaffold a project, run an experiment, do research that produces a deliverable file, anything that needs a long-running coding/research agent operating on the filesystem.

    When in doubt between the two, prefer INLINE. Background tasks are heavyweight.

    Output ONE valid JSON object, no prose, no markdown fences. Schema:

    {
      "routeDecision": "inline" | "background",
      "oneLineTitle": "short title in 3-7 words for the task panel",
      "detailedInstructions": "multi-paragraph expansion of the user's intent into concrete instructions a coding agent can act on",
      "estimatedDuration": "natural-language estimate like 'about 5 minutes' or 'maybe 15 minutes'"
    }

    For inline routes, set oneLineTitle/detailedInstructions/estimatedDuration to empty strings.

    For background routes:
    - oneLineTitle: noun phrase, no trailing punctuation, no quotes. Example: "Tic-tac-toe React app".
    - detailedInstructions: write the plan as if briefing a senior engineer who has filesystem access. Mention concrete deliverables, smoke-test expectations, and where to leave the final output. If the user's request implies looking at their screen, instruct the agent to read any context screenshots saved in the working directory. Do NOT invent details the user didn't ask for. Be honest about ambiguity — if the user said "the paper on my screen" without identifying it, tell the agent to extract the paper's identity from the screenshots first.
    - estimatedDuration: realistic. Most non-trivial coding tasks take 5–15 minutes. Big builds take 20–40. Don't promise "about a minute" for anything substantial.
    """

    private static func buildPlannerUserPrompt(transcript: String) -> String {
        return """
        User's spoken request:

        \(transcript)

        Classify and respond with the JSON object only.
        """
    }

    // MARK: - Output parsing

    private static func parsePlannerOutput(
        plannerOutputText: String,
        userOriginalRequest: String
    ) throws -> AgentTaskPlannerDecision {

        // The classifier prompt asks for a bare JSON object, but defensively
        // strip any accidental code-fence wrapping so we don't fail on model
        // formatting noise.
        let trimmedOutputText = plannerOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonCandidateText = stripCodeFenceWrapping(trimmedOutputText)

        guard let jsonData = jsonCandidateText.data(using: .utf8),
              let parsedObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw AgentTaskPlannerError.plannerJSONUnparseable(rawOutput: plannerOutputText)
        }

        let rawRouteDecision = (parsedObject["routeDecision"] as? String)?.lowercased() ?? "inline"
        if rawRouteDecision != "background" {
            return .routeToInline
        }

        let oneLineTitle = ((parsedObject["oneLineTitle"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detailedInstructions = ((parsedObject["detailedInstructions"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let estimatedDuration = ((parsedObject["estimatedDuration"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let finalTitle = oneLineTitle.isEmpty ? "Background task" : oneLineTitle
        let finalInstructions = detailedInstructions.isEmpty
            ? userOriginalRequest
            : detailedInstructions
        let finalDuration = estimatedDuration.isEmpty
            ? "a few minutes"
            : estimatedDuration

        let workingDirectoryURL = AgentTaskManager.makeWorkingDirectoryURL(forTitle: finalTitle)

        let brief = AgentTaskBrief(
            id: UUID(),
            oneLineTitle: finalTitle,
            userOriginalRequest: userOriginalRequest,
            detailedInstructions: finalInstructions,
            workingDirectoryURL: workingDirectoryURL,
            estimatedDurationDescription: finalDuration,
            maxToolCallSteps: AgentTaskBrief.defaultMaxToolCallSteps,
            maxWallClockSeconds: AgentTaskBrief.defaultMaxWallClockSeconds
        )
        return .routeToBackground(brief: brief)
    }

    private static func stripCodeFenceWrapping(_ candidateText: String) -> String {
        guard candidateText.hasPrefix("```") else { return candidateText }
        var trimmed = candidateText
        if trimmed.hasPrefix("```json") {
            trimmed.removeFirst("```json".count)
        } else if trimmed.hasPrefix("```") {
            trimmed.removeFirst(3)
        }
        if trimmed.hasSuffix("```") {
            trimmed.removeLast(3)
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum AgentTaskPlannerError: Error, LocalizedError {
    case httpFailure(statusCode: Int, bodyText: String)
    case responseFormatInvalid
    case plannerJSONUnparseable(rawOutput: String)

    var errorDescription: String? {
        switch self {
        case .httpFailure(let statusCode, let bodyText):
            return "Planner HTTP \(statusCode): \(bodyText.prefix(200))"
        case .responseFormatInvalid:
            return "Planner response did not match the expected Anthropic shape."
        case .plannerJSONUnparseable(let rawOutput):
            return "Planner returned unparseable JSON: \(rawOutput.prefix(200))"
        }
    }
}
