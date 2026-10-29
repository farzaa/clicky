//
//  ChatGPTAuthenticationManager.swift
//  leanring-buddy
//
//  Sign in with ChatGPT for using a user's eligible ChatGPT plan.
//

import AppKit
import Combine
import CryptoKit
import Foundation
import Network
import Security

struct ChatGPTCredentials: Codable {
    let email: String
    let subject: String
    let clientID: String
    let idToken: String
    let accessToken: String
    let refreshToken: String
    let scopes: [String]
    let accessTokenExpirationDate: Date
}

struct ChatGPTAuthenticationError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private struct ChatGPTOAuthTokenError: LocalizedError {
    let code: String
    let details: String

    var errorDescription: String? {
        "ChatGPT authentication failed: \(details)"
    }
}

@MainActor
final class ChatGPTAuthenticationManager: ObservableObject {
    private static let authorizationURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    private static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    private static let revocationURL = URL(string: "https://auth.openai.com/api/accounts/oauth/revoke")!
    private static let resource = "https://api.openai.com/v1"
    private static let requiredPlanScope = "chatgpt.tokens.use.direct"
    private static let keychainService = "com.makesomething.clicky.chatgpt"
    private static let keychainAccount = "active-credentials"
    private static let registeredClientIDKey = "chatGPTRegisteredClientID"
    private static let registeredSubjectKey = "chatGPTRegisteredSubject"
    private static let hostIDKey = "chatGPTExtAgentHostID"
    private static let acknowledgedPlanUsageKey = "hasAcknowledgedChatGPTPlanUsage"

    @Published private(set) var isSignedIn = false
    @Published private(set) var accountEmail: String?
    @Published private(set) var isSigningIn = false
    @Published private(set) var authenticationErrorMessage: String?
    @Published var shouldShowPlanUsageConfirmation = false

    private var credentials: ChatGPTCredentials?
    private var refreshTask: Task<ChatGPTCredentials, Error>?

    init() {
        credentials = try? Self.readCredentialsFromKeychain()
        isSignedIn = credentials != nil
        accountEmail = credentials?.email
    }

    func signIn() {
        guard !isSigningIn else { return }
        isSigningIn = true
        authenticationErrorMessage = nil

        Task {
            do {
                let newCredentials = try await performSignIn()
                try Self.saveCredentialsToKeychain(newCredentials)
                credentials = newCredentials
                isSignedIn = true
                accountEmail = newCredentials.email
                UserDefaults.standard.set(newCredentials.clientID, forKey: Self.registeredClientIDKey)
                UserDefaults.standard.set(newCredentials.subject, forKey: Self.registeredSubjectKey)
                shouldShowPlanUsageConfirmation = !UserDefaults.standard.bool(
                    forKey: Self.acknowledgedPlanUsageKey
                )
            } catch {
                authenticationErrorMessage = error.localizedDescription
            }
            isSigningIn = false
        }
    }

    /// Starts a separate dynamic registration instead of reusing an issued
    /// client that is bound to a previously selected account and workspace.
    func signInWithAnotherAccountOrWorkspace() {
        guard !isSigningIn else { return }
        credentials = nil
        isSignedIn = false
        accountEmail = nil
        authenticationErrorMessage = nil
        try? Self.deleteCredentialsFromKeychain()
        UserDefaults.standard.removeObject(forKey: Self.registeredClientIDKey)
        UserDefaults.standard.removeObject(forKey: Self.registeredSubjectKey)
        signIn()
    }

    func acknowledgePlanUsage() {
        shouldShowPlanUsageConfirmation = false
        UserDefaults.standard.set(true, forKey: Self.acknowledgedPlanUsageKey)
    }

    func signOut() {
        guard let credentials else { return }
        self.credentials = nil
        isSignedIn = false
        accountEmail = nil
        authenticationErrorMessage = nil
        try? Self.deleteCredentialsFromKeychain()

        Task {
            var request = URLRequest(url: Self.revocationURL)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formEncodedData([
                "token": credentials.refreshToken,
                "token_type_hint": "refresh_token",
                "client_id": credentials.clientID
            ])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func validAccessToken() async throws -> String {
        guard let credentials else {
            throw ChatGPTAuthenticationError(message: "Connect your ChatGPT account first.")
        }

        if credentials.accessTokenExpirationDate.timeIntervalSinceNow > 120 {
            return credentials.accessToken
        }

        if let refreshTask {
            return try await refreshTask.value.accessToken
        }

        let refreshTask = Task { try await Self.refresh(credentials: credentials) }
        self.refreshTask = refreshTask

        do {
            let refreshedCredentials = try await refreshTask.value
            self.refreshTask = nil
            self.credentials = refreshedCredentials
            try Self.saveCredentialsToKeychain(refreshedCredentials)
            return refreshedCredentials.accessToken
        } catch {
            self.refreshTask = nil
            authenticationErrorMessage = "Your ChatGPT session expired. Connect it again."
            throw error
        }
    }

    private func performSignIn(allowInvalidGrantRetry: Bool = true) async throws -> ChatGPTCredentials {
        let loopbackServer = ChatGPTOAuthLoopbackServer()
        let callbackURL = try await loopbackServer.start()
        let state = Self.randomURLSafeString(byteCount: 32)
        let nonce = Self.randomURLSafeString(byteCount: 32)
        let codeVerifier = Self.randomURLSafeString(byteCount: 64)
        let codeChallenge = Self.base64URLEncoded(Data(SHA256.hash(data: Data(codeVerifier.utf8))))
        let savedClientID = credentials?.clientID
            ?? UserDefaults.standard.string(forKey: Self.registeredClientIDKey)
        let authorizationClientID = savedClientID ?? "dynamic_agent_client"

        var authorizationComponents = URLComponents(url: Self.authorizationURL, resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "client_id", value: authorizationClientID),
            URLQueryItem(name: "ext_agent_host_id", value: Self.stableHostID()),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: callbackURL.absoluteString),
            URLQueryItem(name: "scope", value: "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"),
            URLQueryItem(name: "resource", value: Self.resource),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: codeChallenge)
        ]

        if savedClientID == nil {
            queryItems.append(URLQueryItem(name: "agent_name_hint", value: "Clicky"))
        } else if let credentials {
            queryItems.append(URLQueryItem(name: "id_token_hint", value: credentials.idToken))
            queryItems.append(URLQueryItem(name: "login_hint", value: credentials.email))
        }
        authorizationComponents.queryItems = queryItems

        guard let browserURL = authorizationComponents.url else {
            throw ChatGPTAuthenticationError(message: "Could not create the ChatGPT sign-in URL.")
        }
        NSWorkspace.shared.open(browserURL)

        let returnedURL = try await loopbackServer.waitForCallback()
        guard let returnedComponents = URLComponents(url: returnedURL, resolvingAgainstBaseURL: false) else {
            throw ChatGPTAuthenticationError(message: "ChatGPT returned an invalid sign-in response.")
        }
        var returnedValues: [String: String] = [:]
        for queryItem in returnedComponents.queryItems ?? [] where returnedValues[queryItem.name] == nil {
            returnedValues[queryItem.name] = queryItem.value
        }

        guard returnedValues["state"] == state else {
            throw ChatGPTAuthenticationError(message: "ChatGPT sign-in could not be verified. Try again.")
        }
        if let oauthError = returnedValues["error"] {
            throw ChatGPTAuthenticationError(
                message: Self.authorizationErrorMessage(
                    code: oauthError,
                    description: returnedValues["error_description"]
                )
            )
        }
        guard let authorizationCode = returnedValues["code"] else {
            throw ChatGPTAuthenticationError(message: "ChatGPT did not return an authorization code.")
        }

        let issuedClientID = returnedValues["client_id"] ?? savedClientID
        guard let issuedClientID, issuedClientID != "dynamic_agent_client" else {
            throw ChatGPTAuthenticationError(message: "ChatGPT did not complete app registration.")
        }

        var tokenRequest = URLRequest(url: Self.tokenURL)
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        tokenRequest.httpBody = Self.formEncodedData([
            "grant_type": "authorization_code",
            "client_id": issuedClientID,
            "code": authorizationCode,
            "code_verifier": codeVerifier,
            "redirect_uri": callbackURL.absoluteString,
            "resource": Self.resource
        ])

        let tokenResponse: TokenResponse
        do {
            tokenResponse = try await Self.requestTokens(tokenRequest)
        } catch let tokenError as ChatGPTOAuthTokenError
            where tokenError.code == "invalid_grant"
                && allowInvalidGrantRetry
                && authorizationClientID == "dynamic_agent_client" {
            // Dynamic registration can issue the client successfully while the first
            // authorization code is no longer exchangeable. OpenAI requires starting
            // a fresh authorization with that issued client ID rather than registering
            // another client or attempting to reuse the rejected code.
            UserDefaults.standard.set(issuedClientID, forKey: Self.registeredClientIDKey)
            return try await performSignIn(allowInvalidGrantRetry: false)
        }
        let identity = try await ChatGPTIDTokenValidator.validate(
            idToken: tokenResponse.idToken,
            expectedClientID: issuedClientID,
            expectedNonce: nonce
        )
        let expectedSubject = credentials?.subject
            ?? UserDefaults.standard.string(forKey: Self.registeredSubjectKey)
        if let expectedSubject, identity.subject != expectedSubject {
            throw ChatGPTAuthenticationError(
                message: "This Clicky connection belongs to a different ChatGPT account."
            )
        }
        let grantedScopes = tokenResponse.scope.split(separator: " ").map(String.init)
        guard grantedScopes.contains(Self.requiredPlanScope) else {
            throw ChatGPTAuthenticationError(
                message: "ChatGPT plan access was not enabled for Clicky. Reconnect and approve plan usage."
            )
        }

        return ChatGPTCredentials(
            email: identity.email,
            subject: identity.subject,
            clientID: issuedClientID,
            idToken: tokenResponse.idToken,
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            scopes: grantedScopes,
            accessTokenExpirationDate: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        )
    }

    private static func refresh(credentials: ChatGPTCredentials) async throws -> ChatGPTCredentials {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncodedData([
            "grant_type": "refresh_token",
            "client_id": credentials.clientID,
            "refresh_token": credentials.refreshToken,
            "resource": resource
        ])

        let response = try await requestTokens(request)
        let scopes = response.scope.isEmpty
            ? credentials.scopes
            : response.scope.split(separator: " ").map(String.init)
        return ChatGPTCredentials(
            email: credentials.email,
            subject: credentials.subject,
            clientID: credentials.clientID,
            idToken: response.idToken.isEmpty ? credentials.idToken : response.idToken,
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            scopes: scopes,
            accessTokenExpirationDate: Date().addingTimeInterval(TimeInterval(response.expiresIn))
        )
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let idToken: String
        let expiresIn: Int
        let scope: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
            case expiresIn = "expires_in"
            case scope
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try container.decode(String.self, forKey: .accessToken)
            refreshToken = try container.decode(String.self, forKey: .refreshToken)
            idToken = try container.decodeIfPresent(String.self, forKey: .idToken) ?? ""
            expiresIn = try container.decode(Int.self, forKey: .expiresIn)
            scope = try container.decodeIfPresent(String.self, forKey: .scope) ?? ""
        }
    }

    private static func requestTokens(_ request: URLRequest) async throws -> TokenResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseText = String(data: data, encoding: .utf8) ?? "Unknown error"
            let oauthErrorCode = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                ?? "token_exchange_failed"
            throw ChatGPTOAuthTokenError(code: oauthErrorCode, details: responseText)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private static func authorizationErrorMessage(code: String, description: String?) -> String {
        if code == "access_denied" || code == "3p_login_workspace_scope_denied" {
            return description
                ?? "ChatGPT plan access is unavailable for the selected workspace. Try the eligible Personal workspace for your Plus or Pro account, or use an API key."
        }
        return description ?? "ChatGPT sign-in failed: \(code)"
    }

    private static func stableHostID() -> String {
        if let savedHostID = UserDefaults.standard.string(forKey: hostIDKey) {
            return savedHostID
        }
        let newHostID = "urn:uuid:\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(newHostID, forKey: hostIDKey)
        return newHostID
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URLEncoded(Data(bytes))
    }

    fileprivate static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncodedData(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private static func saveCredentialsToKeychain(_ credentials: ChatGPTCredentials) throws {
        let encodedCredentials = try JSONEncoder().encode(credentials)
        let keychainQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let updateStatus = SecItemUpdate(
            keychainQuery as CFDictionary,
            [kSecValueData as String: encodedCredentials] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw ChatGPTAuthenticationError(message: "Could not securely update the ChatGPT session.")
        }

        var addQuery = keychainQuery
        addQuery[kSecValueData as String] = encodedCredentials
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ChatGPTAuthenticationError(message: "Could not securely save the ChatGPT session.")
        }
    }

    private static func readCredentialsFromKeychain() throws -> ChatGPTCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw ChatGPTAuthenticationError(message: "Could not read the saved ChatGPT session.")
        }
        return try JSONDecoder().decode(ChatGPTCredentials.self, from: data)
    }

    private static func deleteCredentialsFromKeychain() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ChatGPTAuthenticationError(message: "Could not remove the saved ChatGPT session.")
        }
    }
}

private final class ChatGPTOAuthLoopbackServer {
    private var listener: NWListener?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var pendingCallbackURL: URL?
    private var hasCompletedStart = false

    func start() async throws -> URL {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            self?.receiveRequest(from: connection, accumulatedData: Data())
        }

        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !self.hasCompletedStart else { return }
                    self.hasCompletedStart = true
                    guard let port = listener.port else {
                        continuation.resume(throwing: ChatGPTAuthenticationError(message: "Could not start ChatGPT sign-in."))
                        return
                    }
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!)
                case .failed(let error):
                    if !self.hasCompletedStart {
                        self.hasCompletedStart = true
                        continuation.resume(throwing: error)
                    } else if let callbackContinuation = self.callbackContinuation {
                        self.callbackContinuation = nil
                        callbackContinuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }
    }

    func waitForCallback() async throws -> URL {
        if let pendingCallbackURL {
            listener?.cancel()
            return pendingCallbackURL
        }
        return try await withCheckedThrowingContinuation { continuation in
            callbackContinuation = continuation
        }
    }

    private func receiveRequest(from connection: NWConnection, accumulatedData: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                callbackContinuation?.resume(throwing: error)
                callbackContinuation = nil
                return
            }
            var completeRequestData = accumulatedData
            if let data {
                completeRequestData.append(data)
            }
            let endOfHeaders = Data("\r\n\r\n".utf8)
            guard completeRequestData.range(of: endOfHeaders) != nil || isComplete else {
                receiveRequest(from: connection, accumulatedData: completeRequestData)
                return
            }
            guard let requestText = String(data: completeRequestData, encoding: .utf8),
                  let requestLine = requestText.components(separatedBy: "\r\n").first else {
                connection.cancel()
                return
            }
            let requestParts = requestLine.split(separator: " ")
            guard requestParts.count >= 2,
                  let callbackURL = URL(string: "http://127.0.0.1\(requestParts[1])"),
                  callbackURL.path == "/auth/callback" else {
                connection.cancel()
                return
            }

            let responseBody = "<html><body style='font-family:-apple-system;text-align:center;padding-top:80px'><h2>Connected to Clicky</h2><p>You can close this window.</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(responseBody.utf8.count)\r\nConnection: close\r\n\r\n\(responseBody)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })

            if let callbackContinuation {
                callbackContinuation.resume(returning: callbackURL)
                self.callbackContinuation = nil
                listener?.cancel()
            } else {
                pendingCallbackURL = callbackURL
            }
        }
    }
}

private enum ChatGPTIDTokenValidator {
    private static let jwksURL = URL(string: "https://auth.openai.com/.well-known/jwks.json")!

    struct Identity {
        let subject: String
        let email: String
    }

    static func validate(
        idToken: String,
        expectedClientID: String,
        expectedNonce: String
    ) async throws -> Identity {
        let tokenParts = idToken.split(separator: ".")
        guard tokenParts.count == 3,
              let headerData = decodeBase64URL(String(tokenParts[0])),
              let claimsData = decodeBase64URL(String(tokenParts[1])),
              let signature = decodeBase64URL(String(tokenParts[2])),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try JSONSerialization.jsonObject(with: claimsData) as? [String: Any],
              header["alg"] as? String == "RS256",
              let keyID = header["kid"] as? String else {
            throw ChatGPTAuthenticationError(message: "ChatGPT returned an invalid identity token.")
        }

        let publicKey = try await fetchPublicKey(keyID: keyID)
        let signedData = Data("\(tokenParts[0]).\(tokenParts[1])".utf8)
        guard SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            signedData as CFData,
            signature as CFData,
            nil
        ) else {
            throw ChatGPTAuthenticationError(message: "ChatGPT identity verification failed.")
        }

        guard claims["iss"] as? String == "https://auth.openai.com",
              audience(claims["aud"], contains: expectedClientID),
              claims["nonce"] as? String == expectedNonce,
              let expiration = claims["exp"] as? NSNumber,
              expiration.doubleValue > Date().timeIntervalSince1970,
              let subject = claims["sub"] as? String,
              let email = claims["email"] as? String else {
            throw ChatGPTAuthenticationError(message: "ChatGPT identity claims could not be verified.")
        }
        return Identity(subject: subject, email: email)
    }

    private static func audience(_ value: Any?, contains expectedClientID: String) -> Bool {
        if let audience = value as? String { return audience == expectedClientID }
        if let audiences = value as? [String] { return audiences.contains(expectedClientID) }
        return false
    }

    private static func fetchPublicKey(keyID: String) async throws -> SecKey {
        let (data, response) = try await URLSession.shared.data(from: jwksURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let keys = payload["keys"] as? [[String: Any]],
              let matchingKey = keys.first(where: { $0["kid"] as? String == keyID }) else {
            throw ChatGPTAuthenticationError(message: "Could not verify the ChatGPT signing key.")
        }

        if let certificateStrings = matchingKey["x5c"] as? [String],
           let firstCertificate = certificateStrings.first,
           let certificateData = Data(base64Encoded: firstCertificate),
           let certificate = SecCertificateCreateWithData(nil, certificateData as CFData),
           let publicKey = SecCertificateCopyKey(certificate) {
            return publicKey
        }

        guard let modulusString = matchingKey["n"] as? String,
              let exponentString = matchingKey["e"] as? String,
              let modulus = decodeBase64URL(modulusString),
              let exponent = decodeBase64URL(exponentString) else {
            throw ChatGPTAuthenticationError(message: "ChatGPT returned an unsupported signing key.")
        }
        return try makeRSAPublicKey(modulus: modulus, exponent: exponent)
    }

    private static func makeRSAPublicKey(modulus: Data, exponent: Data) throws -> SecKey {
        let keyData = derSequence(derInteger(modulus) + derInteger(exponent))
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: modulus.count * 8
        ]
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCreateWithData(keyData as CFData, attributes as CFDictionary, &error) else {
            if let error {
                throw error.takeRetainedValue()
            }
            throw ChatGPTAuthenticationError(message: "Could not create the ChatGPT signing key.")
        }
        return publicKey
    }

    private static func derInteger(_ value: Data) -> Data {
        var normalizedValue = value
        while normalizedValue.count > 1 && normalizedValue.first == 0 { normalizedValue.removeFirst() }
        if let firstByte = normalizedValue.first, firstByte & 0x80 != 0 {
            normalizedValue.insert(0, at: 0)
        }
        return Data([0x02]) + derLength(normalizedValue.count) + normalizedValue
    }

    private static func derSequence(_ value: Data) -> Data {
        Data([0x30]) + derLength(value.count) + value
    }

    private static func derLength(_ length: Int) -> Data {
        if length < 128 { return Data([UInt8(length)]) }
        var remainingLength = length
        var bytes: [UInt8] = []
        while remainingLength > 0 {
            bytes.insert(UInt8(remainingLength & 0xff), at: 0)
            remainingLength >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
