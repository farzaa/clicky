//
//  OpenAIAPI.swift
//  OpenAI Responses API helper
//

import Foundation

class OpenAIAPI {
    private let apiKey: String
    private let apiURL: URL
    private let model: String
    private let session: URLSession

    init(apiKey: String, model: String = "gpt-5.4") {
        self.apiKey = apiKey
        self.apiURL = URL(string: "https://api.openai.com/v1/responses")!
        self.model = model

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration)

        warmUpTLSConnection()
    }

    private func warmUpTLSConnection() {
        var warmupRequest = URLRequest(url: apiURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in
            // Warming the TLS session is enough.
        }.resume()
    }

    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var input: [[String: Any]] = [[
            "role": "system",
            "content": [[
                "type": "input_text",
                "text": systemPrompt
            ]]
        ]]

        for (userPlaceholder, assistantResponse) in conversationHistory {
            input.append([
                "role": "user",
                "content": [[
                    "type": "input_text",
                    "text": userPlaceholder
                ]]
            ])
            input.append([
                "role": "assistant",
                "content": [[
                    "type": "input_text",
                    "text": assistantResponse
                ]]
            ])
        }

        var currentMessageContent: [[String: Any]] = []
        for image in images {
            currentMessageContent.append([
                "type": "input_text",
                "text": image.label
            ])
            currentMessageContent.append([
                "type": "input_image",
                "image_url": "data:image/jpeg;base64,\(image.data.base64EncodedString())"
            ])
        }
        currentMessageContent.append([
            "type": "input_text",
            "text": userPrompt
        ])

        input.append([
            "role": "user",
            "content": currentMessageContent
        ])

        let requestBody: [String: Any] = [
            "model": model,
            "input": input,
            "max_output_tokens": 600
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: requestBody)
        request.httpBody = bodyData

        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 OpenAI Responses request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "OpenAIAPI",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "API Error: \(responseString)"]
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        if let outputText = json?["output_text"] as? String,
           !outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let duration = Date().timeIntervalSince(startTime)
            return (text: outputText, duration: duration)
        }

        let outputItems = json?["output"] as? [[String: Any]] ?? []
        let text = outputItems
            .flatMap { outputItem in
                outputItem["content"] as? [[String: Any]] ?? []
            }
            .compactMap { contentItem -> String? in
                guard let type = contentItem["type"] as? String, type == "output_text" else {
                    return nil
                }
                return contentItem["text"] as? String
            }
            .joined()

        let duration = Date().timeIntervalSince(startTime)
        return (text: text, duration: duration)
    }
}
