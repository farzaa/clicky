//
//  NUClient.swift
//  yardtalk
//
//  Direct HTTPS client for `POST /api/v1/sessions/` on
//  NeighborhoodUnited. PAT auth via `Authorization: Bearer pat_…`,
//  client-generated `Idempotency-Key` header so retries dedupe on
//  the NU side. Per the frozen contract in CLAUDE.md (and PR
//  performlikemj/nbhd-united#330).
//
//  No proxy: the worker is for Anthropic (where we don't ship a key).
//  NU is the user's own platform with their own PAT — direct calls
//  are appropriate.
//
//  Base URL is the dev/azure container app for now; the prod
//  switchover to neighborhoodunited.org happens once the custom
//  domain is live. Override via the `YardTalkNUBaseURL` Info.plist
//  key if you need to point at a different deployment without
//  rebuilding.
//

import Foundation
import OSLog

extension Logger {
    static let nu = Logger(subsystem: "com.yardtalk.app", category: "nu")
}

final class NUClient {
    private let baseURL: URL
    private let pat: String
    private let urlSession: URLSession

    /// Dev base URL per CLAUDE.md. Switch to `neighborhoodunited.org`
    /// once the custom domain is live, or override via Info.plist key
    /// `YardTalkNUBaseURL` (CompanionManager handles the resolution).
    static let defaultBaseURLString = "https://nbhd-django-westus2.victoriousocean-5cdd2683.westus2.azurecontainerapps.io"

    init(pat: String, baseURL: URL) {
        self.pat = pat
        self.baseURL = baseURL

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.urlSession = URLSession(configuration: config)
    }

    /// POSTs `payload` to `/api/v1/sessions/create/`. The
    /// `Idempotency-Key` header is the caller's responsibility — for
    /// YardTalk this is `session.uploadState.idempotencyKey`,
    /// generated lazily on the first attempt and reused for every
    /// retry.
    ///
    /// Note: the frozen-contract section of CLAUDE.md says POST to
    /// `/api/v1/sessions/`, but NU's actual implementation splits
    /// reads (`SessionListView` at `/sessions/`, requires
    /// `sessions:read` scope) from writes (`SessionCreateView` at
    /// `/sessions/create/`, requires `sessions:write` scope). The
    /// docs lag the deployed URLs — write goes to `/create/`.
    func uploadSession(_ payload: NUSessionPayload, idempotencyKey: UUID) async throws {
        // Trailing slash matches Django's APPEND_SLASH default.
        let url = baseURL.appendingPathComponent("api/v1/sessions/create/")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        request.setValue(idempotencyKey.uuidString, forHTTPHeaderField: "Idempotency-Key")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(payload)
        request.httpBody = body

        Logger.nu.info("POST \(url.absoluteString, privacy: .public) idem=\(idempotencyKey.uuidString, privacy: .public) bytes=\(body.count, privacy: .public)")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NUClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            // Truncate before logging and mark .private so the body is
            // redacted in sysdiagnose exports — Django stack traces echo
            // the request payload (session summary, narration, etc.) and
            // we don't want that leaving the device unintentionally.
            let truncated = String(bodyText.prefix(180))
            Logger.nu.error("Upload failed (\(http.statusCode, privacy: .public)): \(truncated, privacy: .private)")
            throw NUClientError.httpError(status: http.statusCode, body: bodyText)
        }
        Logger.nu.info("Upload OK (\(http.statusCode, privacy: .public))")
    }
}

enum NUClientError: LocalizedError {
    case invalidResponse
    case httpError(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "NU returned a non-HTTP response."
        case .httpError(let status, let body):
            // Truncate noisy Django error pages for the inline UI;
            // the full text is in the OS log.
            let preview = body.prefix(180)
            return "NU rejected the upload (HTTP \(status)): \(preview)"
        }
    }
}
