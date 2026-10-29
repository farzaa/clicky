//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
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

    @Test func tftPromptContextIncludesPatchAndDataDragonVersion() async throws {
        let promptContext = TFTMetaPromptBuilder.buildPromptContext()
        let snapshot = TFTMetaKnowledgeBase.currentSnapshot

        #expect(promptContext.contains(snapshot.latestPatchTitle))
        #expect(promptContext.contains(snapshot.dataDragonVersion))
        #expect(promptContext.contains("TFT SNAPSHOT (manual)"))
    }

    @Test func tftStatusMessageMarksSnapshotAsManual() async throws {
        let statusMessage = TFTMetaPromptBuilder.buildStatusMessage()

        #expect(statusMessage.contains("Manual TFT snapshot"))
    }

}
