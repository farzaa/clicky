//
//  OpenAIVisionGuideClient.swift
//  leanring-buddy
//
//  Worker-backed Spider vision guide client. The macOS app never talks to
//  OpenAI directly; the Worker owns credentials, entitlement, quota, and
//  payload validation.
//

import Foundation

final class OpenAIVisionGuideClient {
    private static let maxGuideRequestBytes = 8_000_000
    private static let maxGuideResponseBytes = 1_000_000

    private let guideURL: URL
    private let session: URLSession
    private let tokenProvider: () -> String?

    init(
        guideURL: URL = SpiderConfiguration.endpoint("vision/guide"),
        tokenProvider: @escaping () -> String? = { SpiderConfiguration.sessionBearerToken }
    ) {
        self.guideURL = guideURL
        self.tokenProvider = tokenProvider

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration)
    }

    func guide(
        userTranscript: String,
        screenCaptures: [CompanionScreenCapture],
        conversationHistory: [(userTranscript: String, assistantResponse: String)],
        adMissionSnapshot: AdMission?,
        platformContext: SpiderPlatformContext? = nil,
        guidedSessionContext: SpiderGuidedSessionContext? = nil,
        appLanguage: String
    ) async throws -> SpiderGuideResponse {
        guard !screenCaptures.isEmpty else {
            throw OpenAIVisionGuideClientError.missingScreenshot
        }
        let boundedUserTranscript = userTranscript.spiderSanitizedMultiline(
            maxCharacters: SpiderContentLimits.maxVisionUserTranscriptCharacters
        )
        guard !boundedUserTranscript.isEmpty else {
            throw OpenAIVisionGuideClientError.missingUserTranscript
        }
        guard let token = tokenProvider().flatMap(SpiderWorkerTokenValidator.normalizedDoubleUUIDV4Token) else {
            throw OpenAIVisionGuideClientError.missingSessionToken
        }
        let boundedScreenCaptures = Array(screenCaptures.prefix(SpiderContentLimits.maxGuideScreenshotCount))

        var request = URLRequest(url: guideURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(SpiderConfiguration.deviceIdentifier, forHTTPHeaderField: "X-Spider-Device-ID")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let payload = SpiderVisionGuideRequest(
            userTranscript: boundedUserTranscript,
            appLanguage: appLanguage.spiderSanitizedSingleLine(maxCharacters: SpiderContentLimits.maxAppLanguageCharacters),
            screenshots: boundedScreenCaptures.map { capture in
                SpiderScreenCapturePayload(
                    label: capture.label,
                    imageBase64: capture.imageData.base64EncodedString(),
                    mimeType: "image/jpeg",
                    isCursorScreen: capture.isCursorScreen,
                    displayWidthInPoints: capture.displayWidthInPoints,
                    displayHeightInPoints: capture.displayHeightInPoints,
                    screenshotWidthInPixels: capture.screenshotWidthInPixels,
                    screenshotHeightInPixels: capture.screenshotHeightInPixels
                )
            },
            platformContext: platformContext?.sanitizedForTransmission(),
            guidedSessionContext: guidedSessionContext,
            conversationHistory: Self.boundedConversationHistory(conversationHistory),
            adMissionSnapshot: adMissionSnapshot?.guideSnapshot()
        )

        let requestBody = try JSONEncoder().encode(payload)
        guard requestBody.count <= Self.maxGuideRequestBytes else {
            throw SpiderWorkerClientError(statusCode: 413, operation: "vision_guide")
        }
        request.httpBody = requestBody

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIVisionGuideClientError.invalidWorkerResponse
        }

        guard data.count <= Self.maxGuideResponseBytes else {
            throw OpenAIVisionGuideClientError.oversizedGuideResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw SpiderWorkerClientError(
                statusCode: httpResponse.statusCode,
                operation: "vision_guide"
            )
        }

        do {
            return try JSONDecoder().decode(SpiderGuideResponse.self, from: data).sanitizedForUse()
        } catch {
            throw OpenAIVisionGuideClientError.invalidGuideResponse
        }
    }

    private static func boundedConversationHistory(
        _ conversationHistory: [(userTranscript: String, assistantResponse: String)]
    ) -> [SpiderVisionGuideRequest.ConversationTurn] {
        conversationHistory
            .suffix(SpiderContentLimits.maxVisionConversationHistoryTurns)
            .compactMap { turn in
                let userTranscript = turn.userTranscript.spiderSanitizedMultiline(
                    maxCharacters: SpiderContentLimits.maxVisionHistoryTextCharacters
                )
                let assistantResponse = turn.assistantResponse.spiderSanitizedMultiline(
                    maxCharacters: SpiderContentLimits.maxVisionHistoryTextCharacters
                )
                guard !userTranscript.isEmpty || !assistantResponse.isEmpty else { return nil }
                return SpiderVisionGuideRequest.ConversationTurn(
                    userTranscript: userTranscript,
                    assistantResponse: assistantResponse
                )
            }
    }
}
