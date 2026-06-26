//
//  CompanionGuidePointOverlayPresenterTests.swift
//  leanring-buddyTests
//
//  Tests for accepted guide-point overlay state before CompanionManager mutates UI.
//

import CoreGraphics
import Foundation
import Testing
@testable import Spider

@MainActor
struct CompanionGuidePointOverlayPresenterTests {
    @Test func acceptedPlacementCarriesOverlayStateAndFreshRevision() throws {
        let revision = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000042"))

        let result = CompanionGuidePointOverlayPresenter.application(
            for: SpiderGuidePoint(
                x: 50,
                y: 25,
                label: "  Sales\nTile  ",
                screenNumber: nil,
                missionAlignment: "  Matches\nmission  ",
                targetElementId: "sales_tile",
                expectedOutcome: .tileSelected
            ),
            screenCaptures: [
                CompanionScreenCapture(
                    imageData: Data(),
                    label: "screen",
                    isCursorScreen: true,
                    displayWidthInPoints: 200,
                    displayHeightInPoints: 100,
                    displayFrame: CGRect(x: 10, y: 20, width: 200, height: 100),
                    screenshotWidthInPixels: 100,
                    screenshotHeightInPixels: 50
                ),
            ],
            bubbleText: "  one two three four five six seven eight nine. second sentence.  ",
            makeTargetRevision: { revision }
        )

        #expect(result == .accepted(CompanionGuidePointOverlayState(
            bubbleText: "one two three four five six seven eight",
            pointLabel: "Sales Tile",
            missionAlignment: "Matches mission",
            screenLocation: CGPoint(x: 110, y: 70),
            displayFrame: CGRect(x: 10, y: 20, width: 200, height: 100),
            targetRevision: revision
        )))
    }

    @Test func rejectedPlacementKeepsSpecificReason() {
        let result = CompanionGuidePointOverlayPresenter.application(
            for: SpiderGuidePoint(
                x: 16,
                y: 16,
                label: "Sales",
                screenNumber: 2,
                missionAlignment: "Matches mission",
                targetElementId: "sales_tile",
                expectedOutcome: .tileSelected
            ),
            screenCaptures: [
                CompanionScreenCapture(
                    imageData: Data(),
                    label: "screen",
                    isCursorScreen: true,
                    displayWidthInPoints: 200,
                    displayHeightInPoints: 120,
                    displayFrame: CGRect(x: 0, y: 0, width: 200, height: 120),
                    screenshotWidthInPixels: 200,
                    screenshotHeightInPixels: 120
                ),
            ],
            bubbleText: "Choose this."
        )

        #expect(result == .rejected(.targetScreenUnavailable))
    }
}
