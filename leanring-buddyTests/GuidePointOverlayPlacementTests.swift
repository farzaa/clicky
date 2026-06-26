//
//  GuidePointOverlayPlacementTests.swift
//  leanring-buddyTests
//
//  Tests for pure guide-point coordinate conversion before overlay mutation.
//

import CoreGraphics
import Foundation
import Testing
@testable import Spider

@MainActor
struct GuidePointOverlayPlacementTests {
    @Test func mapsScreenshotPointToAppKitCoordinatesAndSanitizesMetadata() {
        let result = GuidePointOverlayPlacementCalculator.placement(
            for: point(
                x: 50,
                y: 25,
                label: "  Sales\nTile  ",
                missionAlignment: "  Matches\nmission  "
            ),
            screenCaptures: [
                capture(
                    displayFrame: CGRect(x: 10, y: 20, width: 200, height: 100),
                    displayWidthInPoints: 200,
                    displayHeightInPoints: 100,
                    screenshotWidthInPixels: 100,
                    screenshotHeightInPixels: 50
                ),
            ],
            bubbleText: "  one two three four five six seven eight nine. second sentence.  "
        )

        #expect(result == .accepted(GuidePointOverlayPlacement(
            bubbleText: "one two three four five six seven eight",
            pointLabel: "Sales Tile",
            missionAlignment: "Matches mission",
            screenLocation: CGPoint(x: 110, y: 70),
            displayFrame: CGRect(x: 10, y: 20, width: 200, height: 100)
        )))
    }

    @Test func screenNumberTakesPrecedenceOverCursorScreen() {
        let result = GuidePointOverlayPlacementCalculator.placement(
            for: point(x: 25, y: 25, screenNumber: 2),
            screenCaptures: [
                capture(displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), isCursorScreen: true),
                capture(
                    displayFrame: CGRect(x: 300, y: 400, width: 200, height: 100),
                    isCursorScreen: false,
                    displayWidthInPoints: 200,
                    displayHeightInPoints: 100,
                    screenshotWidthInPixels: 100,
                    screenshotHeightInPixels: 100
                ),
            ],
            bubbleText: "Choose this."
        )

        #expect(result == .accepted(GuidePointOverlayPlacement(
            bubbleText: "Choose this.",
            pointLabel: "Sales",
            missionAlignment: "Matches mission",
            screenLocation: CGPoint(x: 350, y: 475),
            displayFrame: CGRect(x: 300, y: 400, width: 200, height: 100)
        )))
    }

    @Test func rejectsUnavailableTargetScreens() {
        #expect(
            GuidePointOverlayPlacementCalculator.placement(
                for: point(x: 16, y: 16, screenNumber: 2),
                screenCaptures: [capture()],
                bubbleText: "Choose this."
            ) == .rejected(.targetScreenUnavailable)
        )
        #expect(
            GuidePointOverlayPlacementCalculator.placement(
                for: point(x: 16, y: 16),
                screenCaptures: [capture(isCursorScreen: false)],
                bubbleText: "Choose this."
            ) == .rejected(.targetScreenUnavailable)
        )
    }

    @Test func rejectsInvalidPointCoordinatesAndScreenDimensions() {
        #expect(
            GuidePointOverlayPlacementCalculator.placement(
                for: point(x: 201, y: 16),
                screenCaptures: [capture()],
                bubbleText: "Choose this."
            ) == .rejected(.pointOutsideScreenshot)
        )
        #expect(
            GuidePointOverlayPlacementCalculator.placement(
                for: point(x: .nan, y: 16),
                screenCaptures: [capture()],
                bubbleText: "Choose this."
            ) == .rejected(.pointOutsideScreenshot)
        )
        #expect(
            GuidePointOverlayPlacementCalculator.placement(
                for: point(x: 16, y: 16),
                screenCaptures: [capture(displayWidthInPoints: 0)],
                bubbleText: "Choose this."
            ) == .rejected(.pointOutsideScreenshot)
        )
    }

    private func point(
        x: Double,
        y: Double,
        label: String = "Sales",
        missionAlignment: String? = "Matches mission",
        screenNumber: Int? = nil
    ) -> SpiderGuidePoint {
        SpiderGuidePoint(
            x: x,
            y: y,
            label: label,
            screenNumber: screenNumber,
            missionAlignment: missionAlignment,
            targetElementId: "sales_tile",
            expectedOutcome: .tileSelected
        )
    }

    private func capture(
        displayFrame: CGRect = CGRect(x: 0, y: 0, width: 200, height: 120),
        isCursorScreen: Bool = true,
        displayWidthInPoints: Int = 200,
        displayHeightInPoints: Int = 120,
        screenshotWidthInPixels: Int = 200,
        screenshotHeightInPixels: Int = 120
    ) -> CompanionScreenCapture {
        CompanionScreenCapture(
            imageData: Data(),
            label: "screen",
            isCursorScreen: isCursorScreen,
            displayWidthInPoints: displayWidthInPoints,
            displayHeightInPoints: displayHeightInPoints,
            displayFrame: displayFrame,
            screenshotWidthInPixels: screenshotWidthInPixels,
            screenshotHeightInPixels: screenshotHeightInPixels
        )
    }
}
