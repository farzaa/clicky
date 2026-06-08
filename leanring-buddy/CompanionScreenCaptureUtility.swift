//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

@MainActor
enum CompanionScreenCaptureUtility {
    private static let maxScreenshotDimensionInPixels = 1280

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        guard WindowPositionManager.hasScreenRecordingPermission() else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Screen recording permission is required"]
            )
        }

        MacOSScreenshotFloatingThumbnailDismisser.dismissIfNeeded()

        let mouseLocation = NSEvent.mouseLocation
        let sortedScreens = NSScreen.screens.sorted { screenA, screenB in
            let aContainsCursor = screenA.frame.contains(mouseLocation)
            let bContainsCursor = screenB.frame.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        guard !sortedScreens.isEmpty else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No display available for capture"]
            )
        }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, screen) in sortedScreens.enumerated() {
            let displayFrame = screen.frame
            let isCursorScreen = displayFrame.contains(mouseLocation)
            let belowWindowID = CoreGraphicsScreenCaptureUtility.topmostOwnedWindowID(on: screen)

            guard let capture = CoreGraphicsScreenCaptureUtility.captureScreenAsJPEG(
                screen: screen,
                belowWindowID: belowWindowID,
                maxDimension: maxScreenshotDimensionInPixels
            ) else {
                continue
            }

            let screenLabel: String
            if sortedScreens.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(sortedScreens.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedScreens.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: capture.imageData,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: capture.screenshotWidthInPixels,
                screenshotHeightInPixels: capture.screenshotHeightInPixels
            ))
        }

        MacOSScreenshotFloatingThumbnailDismisser.dismissIfNeeded()
        MacOSScreenshotFloatingThumbnailDismisser.cleanupTemporaryScreenshotArtifacts()

        guard !capturedScreens.isEmpty else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"]
            )
        }

        return capturedScreens
    }

    /// Verifies screen capture works without invoking ScreenCaptureKit.
    static func verifyScreenCaptureAccess(maxDimension: Int = 64) -> Bool {
        CoreGraphicsScreenCaptureUtility.canCaptureAnyScreen(maxDimension: maxDimension)
    }
}
