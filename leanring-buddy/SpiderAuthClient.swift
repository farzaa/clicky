//
//  SpiderAuthClient.swift
//  leanring-buddy
//
//  Worker auth client for magic-link login and session status. The UI wiring
//  can stay thin because this client owns request shape, token storage, and
//  response validation.
//

import Foundation

struct SpiderLoginStartResponse: Decodable, Equatable {
    let ok: Bool
    let magicLink: URL?
}

struct SpiderLoginConfirmResponse: Decodable, Equatable {
    let sessionToken: String
    let expiresAt: Int
}

struct SpiderLoginStatusResponse: Decodable, Equatable {
    let authenticated: Bool
    let entitlementStatus: String
    let stripeCustomerId: String?
}

struct SpiderBillingSessionResponse: Decodable, Equatable {
    let url: URL
}

struct SpiderLogoutResponse: Decodable, Equatable {
    let ok: Bool
}

enum SpiderEmailAddressValidator {
    private static let maxEmailCharacters = 254
    private static let emailPattern = #"^[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?)+$"#

    static func normalizedEmail(_ value: String) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty,
              trimmedValue.count <= maxEmailCharacters,
              trimmedValue.unicodeScalars.allSatisfy({ $0.value < 128 }),
              trimmedValue.range(
                of: emailPattern,
                options: [.regularExpression, .caseInsensitive]
              ) != nil else {
            return nil
        }
        return trimmedValue.lowercased()
    }
}

final class SpiderAuthClient {
    private static let maxResponseBytes = 262_144
    private static let maxBillingURLCharacters = 8_192
    private static let checkoutSessionHost = "checkout.stripe.com"
    private static let checkoutSessionPathPrefix = "/c/pay/"
    private static let billingPortalSessionHost = "billing.stripe.com"
    private static let billingPortalSessionPathPrefix = "/p/session/"

    private let session: URLSession
    private let tokenStore: SpiderSessionTokenStore

    init(
        session: URLSession = .shared,
        tokenStore: SpiderSessionTokenStore = KeychainSpiderSessionTokenStore()
    ) {
        self.session = session
        self.tokenStore = tokenStore
    }

    func startMagicLinkLogin(email: String) async throws -> SpiderLoginStartResponse {
        guard let normalizedEmail = SpiderEmailAddressValidator.normalizedEmail(email) else {
            throw SpiderAuthClientError.invalidEmail
        }
        var request = URLRequest(url: SpiderConfiguration.endpoint("auth/login/start"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SpiderConfiguration.deviceIdentifier, forHTTPHeaderField: "X-Spider-Device-ID")
        request.httpBody = try JSONEncoder().encode(["email": normalizedEmail])

        return try await perform(request, decoding: SpiderLoginStartResponse.self)
    }

    func confirmMagicLink(token: String) async throws -> SpiderLoginConfirmResponse {
        guard let normalizedToken = SpiderWorkerTokenValidator.normalizedDoubleUUIDV4Token(token) else {
            throw SpiderAuthClientError.invalidMagicLinkToken
        }
        var components = URLComponents(url: SpiderConfiguration.endpoint("auth/login/confirm"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "token", value: normalizedToken)]
        guard let url = components?.url else {
            throw SpiderAuthClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(SpiderConfiguration.deviceIdentifier, forHTTPHeaderField: "X-Spider-Device-ID")

        let response = try await perform(request, decoding: SpiderLoginConfirmResponse.self)
        try tokenStore.saveSessionToken(response.sessionToken)
        return response
    }

    func loginStatus() async throws -> SpiderLoginStatusResponse {
        var request = URLRequest(url: SpiderConfiguration.endpoint("auth/login/status"))
        request.httpMethod = "GET"
        request.setValue(SpiderConfiguration.deviceIdentifier, forHTTPHeaderField: "X-Spider-Device-ID")
        try authorize(&request)
        return try await perform(request, decoding: SpiderLoginStatusResponse.self)
    }

    func logout() throws {
        try tokenStore.clearSessionToken()
    }

    func revokeCurrentSession() async throws -> SpiderLogoutResponse {
        var request = URLRequest(url: SpiderConfiguration.endpoint("auth/logout"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SpiderConfiguration.deviceIdentifier, forHTTPHeaderField: "X-Spider-Device-ID")
        try authorize(&request)

        return try await perform(request, decoding: SpiderLogoutResponse.self)
    }

    func createCheckoutSession() async throws -> SpiderBillingSessionResponse {
        var request = URLRequest(url: SpiderConfiguration.endpoint("billing/checkout"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SpiderConfiguration.deviceIdentifier, forHTTPHeaderField: "X-Spider-Device-ID")
        try authorize(&request)

        return try validatedBillingSession(
            try await perform(request, decoding: SpiderBillingSessionResponse.self),
            expectedHost: Self.checkoutSessionHost,
            expectedPathPrefix: Self.checkoutSessionPathPrefix
        )
    }

    func createBillingPortalSession() async throws -> SpiderBillingSessionResponse {
        var request = URLRequest(url: SpiderConfiguration.endpoint("billing/portal"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SpiderConfiguration.deviceIdentifier, forHTTPHeaderField: "X-Spider-Device-ID")
        try authorize(&request)

        return try validatedBillingSession(
            try await perform(request, decoding: SpiderBillingSessionResponse.self),
            expectedHost: Self.billingPortalSessionHost,
            expectedPathPrefix: Self.billingPortalSessionPathPrefix
        )
    }

    private func authorize(_ request: inout URLRequest) throws {
        let loadedToken = try tokenStore.loadSessionToken() ?? SpiderConfiguration.sessionBearerToken
        guard let token = loadedToken.flatMap(SpiderWorkerTokenValidator.normalizedDoubleUUIDV4Token) else {
            throw SpiderAuthClientError.missingSessionToken
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func validatedBillingSession(
        _ response: SpiderBillingSessionResponse,
        expectedHost: String,
        expectedPathPrefix: String
    ) throws -> SpiderBillingSessionResponse {
        guard response.url.absoluteString.count <= Self.maxBillingURLCharacters,
              response.url.scheme?.lowercased() == "https",
              response.url.host?.lowercased() == expectedHost,
              response.url.path.hasPrefix(expectedPathPrefix),
              response.url.user == nil,
              response.url.password == nil,
              response.url.port == nil else {
            throw SpiderAuthClientError.invalidBillingURL
        }
        return response
    }

    private func perform<ResponseBody: Decodable>(
        _ request: URLRequest,
        decoding responseType: ResponseBody.Type
    ) async throws -> ResponseBody {
        var request = request
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpiderAuthClientError.invalidResponse
        }

        guard data.count <= Self.maxResponseBytes else {
            throw SpiderAuthClientError.responseTooLarge
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw SpiderWorkerClientError(
                statusCode: httpResponse.statusCode,
                operation: "auth"
            )
        }

        return try JSONDecoder().decode(responseType, from: data)
    }
}

protocol SpiderSessionTokenStore {
    func loadSessionToken() throws -> String?
    func saveSessionToken(_ sessionToken: String) throws
    func clearSessionToken() throws
}

struct KeychainSpiderSessionTokenStore: SpiderSessionTokenStore {
    func loadSessionToken() throws -> String? {
        try SpiderSessionStore.loadSessionToken()
    }

    func saveSessionToken(_ sessionToken: String) throws {
        try SpiderSessionStore.saveSessionToken(sessionToken)
    }

    func clearSessionToken() throws {
        try SpiderSessionStore.clearSessionToken()
    }
}

enum SpiderAuthClientError: LocalizedError {
    case invalidBillingURL
    case invalidEmail
    case invalidMagicLinkToken
    case invalidURL
    case invalidResponse
    case missingSessionToken
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidBillingURL:
            return "Spider billing URL is invalid."
        case .invalidEmail:
            return "Spider email address is invalid."
        case .invalidMagicLinkToken:
            return "Spider login link is invalid."
        case .invalidURL:
            return "Spider auth URL is invalid."
        case .invalidResponse:
            return "Spider auth returned an invalid response."
        case .missingSessionToken:
            return "Spider is not logged in."
        case .responseTooLarge:
            return "Spider auth response was too large."
        }
    }
}
