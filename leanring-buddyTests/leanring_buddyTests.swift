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

    @MainActor @Test func menuBarPanelStaysInsideTheRightScreenEdge() async throws {
        let panelOriginX = MenuBarPanelManager.clampedPanelOriginX(
            statusItemFrame: NSRect(x: 1418, y: 878, width: 22, height: 22),
            panelWidth: 320,
            visibleScreenFrame: NSRect(x: 0, y: 0, width: 1440, height: 900)
        )

        #expect(panelOriginX == 1120)
    }

    @MainActor @Test func menuBarPanelStaysInsideTheLeftScreenEdgeOfASecondaryDisplay() async throws {
        let panelOriginX = MenuBarPanelManager.clampedPanelOriginX(
            statusItemFrame: NSRect(x: -1910, y: 1058, width: 22, height: 22),
            panelWidth: 320,
            visibleScreenFrame: NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        )

        #expect(panelOriginX == -1920)
    }

    @MainActor @Test func menuBarPanelStaysCenteredUnderTheIconWhenItFits() async throws {
        let panelOriginX = MenuBarPanelManager.clampedPanelOriginX(
            statusItemFrame: NSRect(x: 1000, y: 878, width: 22, height: 22),
            panelWidth: 320,
            visibleScreenFrame: NSRect(x: 0, y: 0, width: 1440, height: 900)
        )

        #expect(panelOriginX == 851)
    }

    @MainActor @Test func pointTagWithSlightlyNegativeCoordinatesStillPoints() async throws {
        let parseResult = CompanionManager.parsePointingCoordinates(
            from: "it's the close button up top. [POINT:-3,-1:close button]"
        )

        #expect(parseResult.coordinate == CGPoint(x: -3, y: -1))
        #expect(parseResult.elementLabel == "close button")
        #expect(parseResult.spokenText == "it's the close button up top.")
    }

    @MainActor @Test func pointTagWithScreenNumberIsParsed() async throws {
        let parseResult = CompanionManager.parsePointingCoordinates(
            from: "that's on your other monitor. [POINT:400,300:terminal:screen2]"
        )

        #expect(parseResult.coordinate == CGPoint(x: 400, y: 300))
        #expect(parseResult.elementLabel == "terminal")
        #expect(parseResult.screenNumber == 2)
        #expect(parseResult.spokenText == "that's on your other monitor.")
    }

    @MainActor @Test func malformedPointTagIsNeverSpoken() async throws {
        let parseResult = CompanionManager.parsePointingCoordinates(
            from: "click the save button [POINT:12.5,40:save] and you're done."
        )

        #expect(parseResult.coordinate == nil)
        #expect(parseResult.spokenText.contains("[POINT") == false)
    }

}
