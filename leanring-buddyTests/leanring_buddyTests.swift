//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
import Foundation
@testable import leanring_buddy

struct leanring_buddyTests {

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

    @Test func conversationEntryStoresAllFields() {
        let timestamp = Date()
        let entry = ConversationEntry(
            userTranscript: "What is SwiftUI?",
            assistantResponse: "SwiftUI is Apple's declarative UI framework.",
            timestamp: timestamp
        )

        #expect(entry.userTranscript == "What is SwiftUI?")
        #expect(entry.assistantResponse == "SwiftUI is Apple's declarative UI framework.")
        #expect(entry.timestamp == timestamp)
    }

    @Test func conversationEntryHasUniqueIDs() {
        let firstEntry = ConversationEntry(
            userTranscript: "First question",
            assistantResponse: "First answer",
            timestamp: Date()
        )
        let secondEntry = ConversationEntry(
            userTranscript: "Second question",
            assistantResponse: "Second answer",
            timestamp: Date()
        )

        #expect(firstEntry.id != secondEntry.id)
    }

    @Test func conversationEntryIDIsStable() {
        let entry = ConversationEntry(
            userTranscript: "Hello",
            assistantResponse: "Hi there",
            timestamp: Date()
        )

        #expect(entry.id == entry.id)
    }

}
