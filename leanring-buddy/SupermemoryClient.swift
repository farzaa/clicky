//
//  SupermemoryClient.swift
//  leanring-buddy
//
//  Worker-backed long-term memory client. The app never talks to
//  Supermemory directly; the Worker owns the API key.
//

import Foundation

struct SupermemorySearchResult {
    let content: String
    let score: Double?
}

final class SupermemoryClient {
    private let searchURL: URL
    private let addURL: URL
    private let session: URLSession

    init(workerBaseURL: String) {
        self.searchURL = URL(string: "\(workerBaseURL)/memory/search")!
        self.addURL = URL(string: "\(workerBaseURL)/memory/add")!

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: configuration)
    }

    func searchMemories(
        query: String,
        containerTag: String,
        limit: Int = 5
    ) async throws -> [SupermemorySearchResult] {
        let responseData = try await postJSON(
            url: searchURL,
            body: [
                "q": query,
                "containerTag": containerTag,
                "limit": limit,
            ]
        )

        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else {
            return []
        }

        return results.compactMap { result in
            guard let content = Self.extractContent(from: result),
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            let score = result["similarity"] as? Double ?? result["score"] as? Double
            return SupermemorySearchResult(content: content, score: score)
        }
    }

    func addMemory(
        content: String,
        containerTag: String,
        metadata: [String: Any] = [:]
    ) async throws {
        _ = try await postJSON(
            url: addURL,
            body: [
                "content": content,
                "containerTag": containerTag,
                "metadata": metadata,
            ]
        )
    }

    private func postJSON(url: URL, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let responseBody = String(data: data, encoding: .utf8) ?? "unknown"
            throw NSError(
                domain: "SupermemoryClient",
                code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: responseBody]
            )
        }

        return data
    }

    private static func extractContent(from result: [String: Any]) -> String? {
        if let content = result["content"] as? String {
            return content
        }

        if let memory = result["memory"] as? [String: Any],
           let content = memory["content"] as? String {
            return content
        }

        if let chunk = result["chunk"] as? String {
            return chunk
        }

        if let chunk = result["chunk"] as? [String: Any],
           let content = chunk["content"] as? String {
            return content
        }

        if let chunks = result["chunks"] as? [[String: Any]],
           let firstChunkContent = chunks.compactMap({ $0["content"] as? String }).first {
            return firstChunkContent
        }

        return nil
    }
}
