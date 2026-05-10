//
//  VibeIdAccount.swift
//
//  Drop-in macOS account manager for any vibe-id-powered project.
//
//  Usage:
//
//      let account = VibeIdAccount(
//          projectId: "myproject",
//          vibeIdBaseURL: "https://api.accounts.vibe-research.net",
//          appURLScheme: "myproject"
//      )
//
//      // From SwiftUI: @ObservedObject var account: VibeIdAccount
//      // From AppDelegate: account.handleIncomingAuthURL(url) in
//      //                   application(_:open:)
//
//  Companion file: VibeIdInstallTokenStore.swift (Keychain wrapper).
//

import AppKit
import Foundation
import Combine

@MainActor
public final class VibeIdAccount: ObservableObject {

    // MARK: - Published state (drives the panel UI)

    @Published public private(set) var isSignedIn: Bool = false
    @Published public private(set) var isSigningIn: Bool = false
    @Published public private(set) var userEmail: String? = nil
    @Published public private(set) var userDisplayName: String? = nil
    @Published public private(set) var userPictureURL: URL? = nil

    /// Per-endpoint daily limits. Endpoint names match what your project
    /// registered in vibe-id's project_endpoints table (e.g. "chat", "tts").
    @Published public private(set) var dailyLimits: [String: Int] = [:]

    /// Today's usage by project by endpoint. Includes other vibe-id projects
    /// the same user has used, in case you want to show a cross-project view.
    @Published public private(set) var usageTodayByProject: [String: [String: Int]] = [:]

    @Published public private(set) var lastErrorMessage: String? = nil

    // MARK: - Configuration

    public let projectId: String
    public let appURLScheme: String
    private let vibeIdBaseURL: String
    private let urlSession: URLSession

    /// Stable per-install identifier sent to vibe-id so re-signing in on the
    /// same Mac re-uses the same `devices` row instead of creating a new one.
    /// Persisted in UserDefaults, scoped per-project so multiple vibe-id
    /// apps on the same Mac don't collide.
    private var stableDeviceIdentifier: String {
        let key = "VibeIdAccount.\(projectId).deviceIdentifier"
        if let cached = UserDefaults.standard.string(forKey: key), !cached.isEmpty {
            return cached
        }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }

    // MARK: - Init

    public init(projectId: String, vibeIdBaseURL: String, appURLScheme: String) {
        self.projectId = projectId
        self.vibeIdBaseURL = vibeIdBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.appURLScheme = appURLScheme

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.urlSession = URLSession(configuration: configuration)

        // Surface a "signed in" state immediately if the Keychain still has
        // a token; refresh user details from /auth/me right after.
        if VibeIdInstallTokenStore.currentInstallToken(forProjectId: projectId) != nil {
            self.isSignedIn = true
            Task { await self.refreshCurrentUser() }
        }
    }

    // MARK: - Public API

    /// Opens the system browser to start the Google sign-in flow on vibe-id.
    public func signIn() {
        guard !isSigningIn else { return }
        lastErrorMessage = nil
        isSigningIn = true

        var components = URLComponents(string: "\(vibeIdBaseURL)/auth/start")
        components?.queryItems = [
            URLQueryItem(name: "project", value: projectId),
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

    /// Call from AppDelegate's `application(_:open:)` to handle the
    /// `<scheme>://auth?code=…` URL macOS routes back from the browser.
    /// Returns true if the URL was a recognized auth URL.
    @discardableResult
    public func handleIncomingAuthURL(_ incomingURL: URL) -> Bool {
        guard incomingURL.scheme == appURLScheme, incomingURL.host == "auth" else {
            return false
        }
        let queryItems = URLComponents(url: incomingURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let authCode = queryItems.first(where: { $0.name == "code" })?.value, !authCode.isEmpty else {
            lastErrorMessage = "Sign-in URL was missing a code."
            isSigningIn = false
            return true
        }

        Task { [weak self] in await self?.exchangeAuthCodeForInstallToken(authCode: authCode) }
        return true
    }

    public func signOut() {
        Task { [weak self] in await self?.callSignOutEndpoint() }
        VibeIdInstallTokenStore.deleteInstallToken(forProjectId: projectId)
        isSignedIn = false
        userEmail = nil
        userDisplayName = nil
        userPictureURL = nil
        dailyLimits = [:]
        usageTodayByProject = [:]
    }

    /// Pulls the latest user profile + today's quota usage from vibe-id /auth/me.
    public func refreshCurrentUser() async {
        guard let installToken = VibeIdInstallTokenStore.currentInstallToken(forProjectId: projectId) else {
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
                VibeIdInstallTokenStore.deleteInstallToken(forProjectId: projectId)
                isSignedIn = false
                userEmail = nil
                return
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                lastErrorMessage = "Couldn't load your account (status \(httpResponse.statusCode))."
                return
            }

            let parsed = try JSONDecoder().decode(AuthMeResponse.self, from: data)
            applySnapshot(user: parsed.user, quotas: parsed.quotas, usage: parsed.usage_today_by_project)
        } catch {
            lastErrorMessage = "Couldn't reach the identity server: \(error.localizedDescription)"
        }
    }

    // MARK: - Private — server calls

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

            let savedSuccessfully = VibeIdInstallTokenStore.saveInstallToken(
                parsed.install_token,
                forProjectId: projectId
            )
            guard savedSuccessfully else {
                lastErrorMessage = "Couldn't save your sign-in to the macOS Keychain. Try again, and click Always Allow if macOS asks for your password."
                return
            }
            applySnapshot(user: parsed.user, quotas: parsed.quotas, usage: [:])
            isSignedIn = true
            await refreshCurrentUser()
        } catch {
            lastErrorMessage = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    private func callSignOutEndpoint() async {
        guard let installToken = VibeIdInstallTokenStore.currentInstallToken(forProjectId: projectId),
              let signOutURL = URL(string: "\(vibeIdBaseURL)/auth/signout") else { return }
        var request = URLRequest(url: signOutURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(installToken)", forHTTPHeaderField: "Authorization")
        _ = try? await urlSession.data(for: request)
    }

    private func applySnapshot(user: VibeIdUser, quotas: [String: Int], usage: [String: [String: Int]]) {
        userEmail = user.email
        userDisplayName = user.display_name
        if let pictureURLString = user.picture_url, let pictureURL = URL(string: pictureURLString) {
            userPictureURL = pictureURL
        } else {
            userPictureURL = nil
        }
        dailyLimits = quotas
        usageTodayByProject = usage
    }
}

// MARK: - Wire types

private struct AuthExchangeResponse: Decodable {
    let install_token: String
    let user: VibeIdUser
    let quotas: [String: Int]?
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
