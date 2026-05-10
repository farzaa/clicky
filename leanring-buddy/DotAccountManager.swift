//
//  DotAccountManager.swift
//  leanring-buddy
//
//  Owns the Google sign-in flow and the resulting user/session state. The
//  install token (long-lived bearer) lives in the Keychain via
//  DotInstallTokenStore. This class exposes published UI state plus the
//  callbacks that drive the OAuth round-trip.
//
//  Sign-in flow:
//    1. User clicks "Sign in with Google" in the panel.
//    2. signIn() opens the system browser to <proxy>/auth/start?device_id=…
//    3. User picks a Google account in the browser.
//    4. The Worker callback redirects to dot://auth?code=…&email=… which
//       macOS routes back to the app via the dot:// URL scheme.
//    5. CompanionAppDelegate forwards the URL to handleIncomingAuthURL(),
//       which POSTs the code to /auth/exchange and gets a long-lived
//       install token. The token is saved to the Keychain.
//    6. We immediately fetch /auth/me to populate user info + today's quota.
//

import AppKit
import Foundation
import Combine

@MainActor
final class DotAccountManager: ObservableObject {

    // MARK: - Published state

    @Published private(set) var isSignedIn: Bool = false
    @Published private(set) var isSigningIn: Bool = false
    @Published private(set) var userEmail: String? = nil
    @Published private(set) var userDisplayName: String? = nil
    @Published private(set) var userPictureURL: URL? = nil
    @Published private(set) var dailyChatLimit: Int? = nil
    @Published private(set) var dailyTtsCharsLimit: Int? = nil
    @Published private(set) var dailyTranscribeSessionLimit: Int? = nil
    @Published private(set) var todayChatCount: Int = 0
    @Published private(set) var todayTtsChars: Int = 0
    @Published private(set) var todayTranscribeSessions: Int = 0
    @Published private(set) var lastErrorMessage: String? = nil

    // MARK: - Private

    private let proxyBaseURL: String
    private let urlSession: URLSession

    /// Stable per-install identifier sent to the Worker so a second sign-in on
    /// the same Mac re-uses the same `devices` row instead of creating a new one.
    private var stableDeviceIdentifier: String {
        if let cachedDeviceIdentifier = UserDefaults.standard.string(forKey: deviceIdentifierUserDefaultsKey),
           !cachedDeviceIdentifier.isEmpty {
            return cachedDeviceIdentifier
        }
        let newDeviceIdentifier = UUID().uuidString
        UserDefaults.standard.set(newDeviceIdentifier, forKey: deviceIdentifierUserDefaultsKey)
        return newDeviceIdentifier
    }
    private let deviceIdentifierUserDefaultsKey = "DotAccount.deviceIdentifier"

    // MARK: - Init

    init(proxyBaseURL: String = AppBundleConfiguration.proxyBaseURLString()) {
        self.proxyBaseURL = proxyBaseURL

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.urlSession = URLSession(configuration: configuration)

        // Surface a "signed in" state immediately if the Keychain still has a
        // valid token. We refresh user details from /auth/me right after.
        if DotInstallTokenStore.currentInstallToken() != nil {
            self.isSignedIn = true
            Task { await self.refreshCurrentUser() }
        }
    }

    // MARK: - Public API

    /// Opens the system browser to start the Google sign-in flow.
    func signIn() {
        guard !isSigningIn else { return }
        lastErrorMessage = nil
        isSigningIn = true

        var urlComponents = URLComponents(string: "\(proxyBaseURL)/auth/start")
        urlComponents?.queryItems = [
            URLQueryItem(name: "device_id", value: stableDeviceIdentifier),
        ]

        guard let signInUrl = urlComponents?.url else {
            isSigningIn = false
            lastErrorMessage = "Couldn't build the sign-in URL."
            return
        }

        NSWorkspace.shared.open(signInUrl)

        // We don't have a great way to know when the user actually finished or
        // abandoned the flow. Auto-clear the spinner after a generous timeout
        // so the UI doesn't get stuck if they close the browser tab without
        // signing in.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000) // 120 seconds
            guard let self else { return }
            if !self.isSignedIn {
                self.isSigningIn = false
            }
        }
    }

    /// Called from CompanionAppDelegate when macOS routes a dot:// URL back to
    /// the app after the user finishes signing in. Returns true if the URL was
    /// handled, false if it wasn't a recognized auth URL.
    @discardableResult
    func handleIncomingAuthURL(_ incomingURL: URL) -> Bool {
        guard incomingURL.scheme == "dot",
              incomingURL.host == "auth" else {
            return false
        }
        let queryItems = URLComponents(url: incomingURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let authCode = queryItems.first(where: { $0.name == "code" })?.value, !authCode.isEmpty else {
            lastErrorMessage = "Sign-in URL was missing a code."
            isSigningIn = false
            return true
        }

        Task { [weak self] in
            await self?.exchangeAuthCodeForInstallToken(authCode: authCode)
        }
        return true
    }

    /// Revokes the install token on the server and clears local state.
    func signOut() {
        Task { [weak self] in
            await self?.callSignOutEndpoint()
        }
        DotInstallTokenStore.deleteInstallToken()
        isSignedIn = false
        userEmail = nil
        userDisplayName = nil
        userPictureURL = nil
        dailyChatLimit = nil
        dailyTtsCharsLimit = nil
        dailyTranscribeSessionLimit = nil
        todayChatCount = 0
        todayTtsChars = 0
        todayTranscribeSessions = 0
    }

    /// Pulls the latest user profile + today's quota usage from /auth/me.
    func refreshCurrentUser() async {
        guard let installToken = DotInstallTokenStore.currentInstallToken() else {
            isSignedIn = false
            return
        }

        guard let meURL = URL(string: "\(proxyBaseURL)/auth/me") else { return }
        var meRequest = URLRequest(url: meURL)
        meRequest.httpMethod = "GET"
        meRequest.setValue("Bearer \(installToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await urlSession.data(for: meRequest)
            guard let httpResponse = response as? HTTPURLResponse else { return }

            if httpResponse.statusCode == 401 {
                // Token was revoked or invalidated server-side. Clear local state.
                DotInstallTokenStore.deleteInstallToken()
                isSignedIn = false
                userEmail = nil
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                lastErrorMessage = "Couldn't load your account (status \(httpResponse.statusCode))."
                return
            }

            let parsedResponse = try JSONDecoder().decode(AuthMeResponse.self, from: data)
            applyUserProfile(parsedResponse)
        } catch {
            lastErrorMessage = "Couldn't reach the Dot server: \(error.localizedDescription)"
        }
    }

    // MARK: - Private — server calls

    private func exchangeAuthCodeForInstallToken(authCode: String) async {
        defer { isSigningIn = false }

        guard let exchangeURL = URL(string: "\(proxyBaseURL)/auth/exchange") else { return }

        let exchangeBody: [String: Any] = [
            "code": authCode,
            "device_id": stableDeviceIdentifier,
            "device_label": (Host.current().localizedName ?? "mac"),
        ]

        var exchangeRequest = URLRequest(url: exchangeURL)
        exchangeRequest.httpMethod = "POST"
        exchangeRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        exchangeRequest.httpBody = try? JSONSerialization.data(withJSONObject: exchangeBody)

        do {
            let (data, response) = try await urlSession.data(for: exchangeRequest)
            guard let httpResponse = response as? HTTPURLResponse else {
                lastErrorMessage = "Sign-in failed (no response)."
                return
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                let errorBody = String(data: data, encoding: .utf8) ?? ""
                lastErrorMessage = "Sign-in failed (status \(httpResponse.statusCode)). \(errorBody)"
                return
            }

            let exchangeResponse = try JSONDecoder().decode(AuthExchangeResponse.self, from: data)

            DotInstallTokenStore.saveInstallToken(exchangeResponse.install_token)
            applyUserProfile(AuthMeResponse(user: exchangeResponse.user, usage: nil))
            isSignedIn = true
            await refreshCurrentUser()
        } catch {
            lastErrorMessage = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    private func callSignOutEndpoint() async {
        guard let installToken = DotInstallTokenStore.currentInstallToken(),
              let signOutURL = URL(string: "\(proxyBaseURL)/auth/signout") else { return }

        var signOutRequest = URLRequest(url: signOutURL)
        signOutRequest.httpMethod = "POST"
        signOutRequest.setValue("Bearer \(installToken)", forHTTPHeaderField: "Authorization")
        // We don't care about the response body — best-effort.
        _ = try? await urlSession.data(for: signOutRequest)
    }

    private func applyUserProfile(_ response: AuthMeResponse) {
        userEmail = response.user.email
        userDisplayName = response.user.display_name
        if let pictureURLString = response.user.picture_url, let pictureURL = URL(string: pictureURLString) {
            userPictureURL = pictureURL
        } else {
            userPictureURL = nil
        }
        dailyChatLimit = response.user.daily_chat_limit
        dailyTtsCharsLimit = response.user.daily_tts_chars_limit
        dailyTranscribeSessionLimit = response.user.daily_transcribe_session_limit

        if let usage = response.usage {
            todayChatCount = usage.chat_count
            todayTtsChars = usage.tts_chars
            todayTranscribeSessions = usage.transcribe_sessions
        }
    }
}

// MARK: - Wire types

private struct AuthExchangeResponse: Decodable {
    let install_token: String
    let user: DotUser
}

private struct AuthMeResponse: Decodable {
    let user: DotUser
    let usage: DotUsage?
}

private struct DotUser: Decodable {
    let id: Int
    let email: String
    let display_name: String?
    let picture_url: String?
    let daily_chat_limit: Int
    let daily_tts_chars_limit: Int
    let daily_transcribe_session_limit: Int
}

private struct DotUsage: Decodable {
    let chat_count: Int
    let tts_chars: Int
    let transcribe_sessions: Int
}
