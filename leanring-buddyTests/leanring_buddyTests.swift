//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import AppKit
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

    @Test func menuBarPanelStaysInsideTheRightScreenEdge() async throws {
        let panelOriginX = MenuBarPanelManager.clampedPanelOriginX(
            statusItemFrame: NSRect(x: 1418, y: 878, width: 22, height: 22),
            panelWidth: 320,
            visibleScreenFrame: NSRect(x: 0, y: 0, width: 1440, height: 900)
        )

        #expect(panelOriginX == 1120)
    }

    @Test func menuBarPanelStaysInsideTheLeftScreenEdge() async throws {
        let panelOriginX = MenuBarPanelManager.clampedPanelOriginX(
            statusItemFrame: NSRect(x: -1920, y: 1058, width: 22, height: 22),
            panelWidth: 320,
            visibleScreenFrame: NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        )

        #expect(panelOriginX == -1920)
    }

    @Test func menuBarPanelRemainsCenteredWhenItFits() async throws {
        let panelOriginX = MenuBarPanelManager.clampedPanelOriginX(
            statusItemFrame: NSRect(x: 1000, y: 878, width: 22, height: 22),
            panelWidth: 320,
            visibleScreenFrame: NSRect(x: 0, y: 0, width: 1440, height: 900)
        )

        #expect(panelOriginX == 851)
    }

}
