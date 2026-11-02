//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Foundation
import Testing
@testable import leanring_buddy

struct leanring_buddyTests {

    @Test func workerConfigurationAcceptsHTTPSAndNormalizesItsBaseURL() throws {
        let configurationData = Data(#"{"workerBaseURL":"https://clicky.example.workers.dev/"}"#.utf8)

        let workerBaseURL = try WorkerProxyConfiguration.workerBaseURL(from: configurationData)

        #expect(workerBaseURL.absoluteString == "https://clicky.example.workers.dev")
    }

    @Test func workerConfigurationAllowsHTTPOnlyForLocalDevelopment() throws {
        let configurationData = Data(#"{"workerBaseURL":"http://localhost:8787"}"#.utf8)

        let workerBaseURL = try WorkerProxyConfiguration.workerBaseURL(from: configurationData)

        #expect(workerBaseURL.absoluteString == "http://localhost:8787")
    }

    @Test func workerConfigurationRejectsRemoteHTTP() {
        let configurationData = Data(#"{"workerBaseURL":"http://clicky.example.workers.dev"}"#.utf8)

        #expect(throws: WorkerProxyConfigurationError.invalidConfiguration) {
            try WorkerProxyConfiguration.workerBaseURL(from: configurationData)
        }
    }

    @Test func workerConfigurationRejectsURLsWithPathsOrCredentials() {
        let configurationValues = [
            #"{"workerBaseURL":"https://clicky.example.workers.dev/chat"}"#,
            #"{"workerBaseURL":"https://user:password@clicky.example.workers.dev"}"#
        ]

        for configurationValue in configurationValues {
            #expect(throws: WorkerProxyConfigurationError.invalidConfiguration) {
                try WorkerProxyConfiguration.workerBaseURL(from: Data(configurationValue.utf8))
            }
        }
    }

    @Test func workerConfigurationCreatesAuthorizedEndpointRequests() throws {
        let configuration = WorkerProxyConfiguration(
            workerBaseURL: URL(string: "https://clicky.example.workers.dev/"),
            authorizationToken: "local-test-token"
        )
        var request = URLRequest(url: try configuration.endpoint(for: "chat"))

        try configuration.authorize(&request)

        #expect(request.url?.absoluteString == "https://clicky.example.workers.dev/chat")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer local-test-token")
    }

    @Test func workerConfigurationRejectsRequestsWithoutToken() {
        let configuration = WorkerProxyConfiguration(
            workerBaseURL: URL(string: "https://clicky.example.workers.dev"),
            authorizationToken: nil
        )
        var request = URLRequest(url: URL(string: "https://clicky.example.workers.dev/chat")!)

        #expect(throws: WorkerProxyConfigurationError.missingToken) {
            try configuration.authorize(&request)
        }
    }

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

}
