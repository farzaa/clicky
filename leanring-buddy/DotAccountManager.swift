//
//  DotAccountManager.swift
//  leanring-buddy
//
//  Talks to the central vibe-id identity service for sign-in, /auth/me, and
//  sign-out. The install token returned by vibe-id is scoped to project=dot;
//  the rest of the app sends it as Bearer auth on every dot-proxy request.
//

import AppKit
import Foundation

@MainActor
final class DotAccountManager: ObservableObject {
    @Published private(set) var isSignedIn: Bool = false
    @Published private(set) var isSigningIn: Bool = false
    @Published private(set) var userEmail: String? = nil
    @Published private(set) var userDisplayName: String? = nil
    @Published private(set) var userPictureURL: URL? = nil
    @Published private(set) var dailyChatLimit: Int? = nil
    @Published private(set) var todayChatCount: Int = 0
    @Published private(set) var lastErrorMessage: String? = nil

    private static let projectId = "dot"
    private let vibeIdBaseURL: String
    private let urlSession: URLSession

    private var stableDeviceIdentifier: String {
        if let cached = UserDefaults.standard.string(forKey: "DotAccount.deviceIdentifier"),
           !cached.isEmpty {
            return cached
        }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: "DotAccount.deviceIdentifier")
        return new
    }

    init(vibeIdBaseURL: String = AppBundleConfiguration.vibeIdBaseURLString()) {
        self.vibeIdBaseURL = vibeIdBaseURL

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.urlSession = URLSession(configuration: configuration)

        if DotInstallTokenStore.currentInstallToken() != nil {
            self.isSignedIn = true
            Task { await self.refreshCurrentUser() }
        }
    }

    func signIn() {
        guard !isSigningIn else { return }
        lastErrorMessage = nil
        isSigningIn = true

        var components = URLComponents(string: "\(vibeIdBaseURL)/auth/start")
        components?.queryItems = [
            URLQueryItem(name: "project", value: Self.projectId),
            URLQueryItem(name: "device_id", value: stableDeviceIdentifier),
        ]

        guard let signInUrl = components?.url else {
            isSigningIn = false
            lastErrorMessage = "Couldn't build the sign-in URL."
            return
        }
        NSWorkspace.shared.open(signInUrl)

        // Auto-clear the spinner if the user closes the browser without finishing.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard let self else { return }
            if !self.isSignedIn { self.isSigningIn = false }
        }
    }

    /// Called from CompanionAppDelegate when macOS routes a dot:// URL back to
    /// the app after the user finishes signing in.
    @discardableResult
    func handleIncomingAuthURL(_ incomingURL: URL) -> Bool {
        guard incomingURL.scheme == "dot", incomingURL.host == "auth" else { return false }
        let queryItems = URLComponents(url: incomingURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let authCode = queryItems.first(where: { $0.name == "code" })?.value, !authCode.isEmpty else {
            lastErrorMessage = "Sign-in URL was missing a code."
            isSigningIn = false
            return true
        }

        Task { [weak self] in await self?.exchangeAuthCodeForInstallToken(authCode: authCode) }
        return true
    }

    func signOut() {
        Task { [weak self] in await self?.callSignOutEndpoint() }
        DotInstallTokenStore.deleteInstallToken()
        isSignedIn = false
        userEmail = nil
        userDisplayName = nil
        userPictureURL = nil
        dailyChatLimit = nil
        todayChatCount = 0
    }

    func refreshCurrentUser() async {
        guard let installToken = DotInstallTokenStore.currentInstallToken() else {
            isSignedIn = false
            return
        }

        guard let meURL = URL(string: "\(vibeIdBaseURL)/auth/me") else { return }
        var meRequest = URLRequest(url: meURL)
        meRequest.setValue("Bearer \(installToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await urlSession.data(for: meRequest)
            guard let httpResponse = response as? HTTPURLResponse else { return }

            if httpResponse.statusCode == 401 {
                DotInstallTokenStore.deleteInstallToken()
                isSignedIn = false
                userEmail = nil
                return
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                lastErrorMessage = "Couldn't load your account (status \(httpResponse.statusCode))."
                return
            }

            let parsed = try JSONDecoder().decode(AuthMeResponse.self, from: data)
            applyAccountSnapshot(user: parsed.user, quotas: parsed.quotas, usageForCurrentProject: parsed.usage_today_by_project[Self.projectId] ?? [:])
        } catch {
            lastErrorMessage = "Couldn't reach the identity server: \(error.localizedDescription)"
        }
    }

    private func exchangeAuthCodeForInstallToken(authCode: String) async {
        defer { isSigningIn = false }

        guard let exchangeURL = URL(string: "\(vibeIdBaseURL)/auth/exchange") else { return }

        let body: [String: Any] = [
            "code": authCode,
            "device_id": stableDeviceIdentifier,
            "device_label": (Host.current().localizedName ?? "mac"),
        ]

        var request = URLRequest(url: exchangeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                lastErrorMessage = "Sign-in failed (no response)."
                return
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                let errorBody = String(data: data, encoding: .utf8) ?? ""
                lastErrorMessage = "Sign-in failed (status \(httpResponse.statusCode)). \(errorBody)"
                return
            }

            let parsed = try JSONDecoder().decode(AuthExchangeResponse.self, from: data)

            let savedSuccessfully = DotInstallTokenStore.saveInstallToken(parsed.install_token)
            guard savedSuccessfully else {
                lastErrorMessage = "Couldn't save your sign-in to the macOS Keychain. Try again, and click Always Allow if macOS asks for your password."
                return
            }
            applyAccountSnapshot(user: parsed.user, quotas: parsed.quotas, usageForCurrentProject: [:])
            isSignedIn = true
            await refreshCurrentUser()
        } catch {
            lastErrorMessage = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    private func callSignOutEndpoint() async {
        guard let installToken = DotInstallTokenStore.currentInstallToken(),
              let signOutURL = URL(string: "\(vibeIdBaseURL)/auth/signout") else { return }
        var request = URLRequest(url: signOutURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(installToken)", forHTTPHeaderField: "Authorization")
        _ = try? await urlSession.data(for: request)
    }

    private func applyAccountSnapshot(user: VibeIdUser, quotas: [String: Int], usageForCurrentProject: [String: Int]) {
        userEmail = user.email
        userDisplayName = user.display_name
        if let pictureURLString = user.picture_url, let pictureURL = URL(string: pictureURLString) {
            userPictureURL = pictureURL
        } else {
            userPictureURL = nil
        }
        dailyChatLimit = quotas["chat"]
        todayChatCount = usageForCurrentProject["chat"] ?? 0
    }
}

private struct AuthExchangeResponse: Decodable {
    let install_token: String
    let user: VibeIdUser
    let quotas: [String: Int]
}

private struct AuthMeResponse: Decodable {
    let user: VibeIdUser
    let quotas: [String: Int]
    let usage_today_by_project: [String: [String: Int]]
}

private struct VibeIdUser: Decodable {
    let id: Int
    let email: String
    let display_name: String?
    let picture_url: String?
}
