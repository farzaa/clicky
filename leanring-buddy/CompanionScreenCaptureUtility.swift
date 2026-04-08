//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayFrame: CGRect
    /// How `displayFrame` was chosen relative to `NSScreen.frame` vs `SCContentFilter.contentRect` (for logs / debugging).
    let displayFrameMappingSourceDescription: String
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int

    /// Rounded point dimensions for prompts and logging (avoid `Int(frame)` truncation skew).
    var displayWidthInPoints: Int { Int(round(displayFrame.width)) }
    var displayHeightInPoints: Int { Int(round(displayFrame.height)) }

    /// Maps a point from screenshot image space (origin top-left, pixels) to AppKit global
    /// coordinates (same space as `NSEvent.mouseLocation` and `CGEvent` posting).
    func globalAppKitPointFromScreenshotPixelCoordinate(screenshotPixelX: CGFloat, screenshotPixelY: CGFloat) -> CGPoint {
        let screenshotWidth = CGFloat(screenshotWidthInPixels)
        let screenshotHeight = CGFloat(screenshotHeightInPixels)
        let displayWidth = displayFrame.width
        let displayHeight = displayFrame.height

        let clampedX = max(0, min(screenshotPixelX, screenshotWidth))
        let clampedY = max(0, min(screenshotPixelY, screenshotHeight))
        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)
        let appKitY = displayHeight - displayLocalY
        return CGPoint(x: displayLocalX + displayFrame.origin.x, y: appKitY + displayFrame.origin.y)
    }
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Builds the mapping frame used to convert screenshot pixels to AppKit global points.
    /// Origin must remain AppKit-global (`NSScreen.frame.origin`) so point conversion aligns
    /// with CGEvent/NSEvent coordinates; size should come from what ScreenCaptureKit captured.
    private static func displayFrameForMappingScreenshotToGlobalMouse(
        nsscreenFrame: CGRect?,
        filterContentRect: CGRect,
        displayID: CGDirectDisplayID
    ) -> (frame: CGRect, mappingSourceDescription: String) {
        let contentRect = filterContentRect
        guard let nsFrame = nsscreenFrame else {
            print(
                "⚠️ CompanionScreenCapture: no NSScreen for displayID \(displayID); " +
                "using SCContentFilter.contentRect for click/pointer mapping"
            )
            return (contentRect, "content_rect_no_matching_nsscreen")
        }

        let epsilon: CGFloat = 0.5
        let sizesMatch =
            abs(nsFrame.width - contentRect.width) < epsilon
            && abs(nsFrame.height - contentRect.height) < epsilon

        if sizesMatch {
            return (nsFrame, "nsscreen_matches_content_filter")
        }

        let contentRectHasUsableSize = contentRect.width >= 1 && contentRect.height >= 1
        if contentRectHasUsableSize {
            let mappingFrame = CGRect(
                x: nsFrame.origin.x,
                y: nsFrame.origin.y,
                width: contentRect.width,
                height: contentRect.height
            )
            print(
                "🖼️ CompanionScreenCapture: mapping frame uses NSScreen origin + contentRect size " +
                "(displayID \(displayID)) nsscreenFrame=\(nsFrame) contentRect=\(contentRect) " +
                "mappingFrame=\(mappingFrame)"
            )
            return (mappingFrame, "global_origin_from_nsscreen_size_from_content_rect")
        }

        print(
            "⚠️ CompanionScreenCapture: contentRect size unusable; using NSScreen.frame for mapping " +
            "(displayID \(displayID)) nsscreenFrame=\(nsFrame) contentRect=\(contentRect)"
        )
        return (nsFrame, "global_origin_and_size_from_nsscreen_fallback")
    }

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)
            filter.includeMenuBar = true

            let nsscreenForDisplay = nsScreenByDisplayID[display.displayID]
            var contentRect = filter.contentRect
            if contentRect.width < 1 || contentRect.height < 1, let fallback = nsscreenForDisplay?.frame {
                contentRect = fallback
            }

            let nsscreenFrame = nsscreenForDisplay?.frame
            let mappingChoice = displayFrameForMappingScreenshotToGlobalMouse(
                nsscreenFrame: nsscreenFrame,
                filterContentRect: contentRect,
                displayID: display.displayID
            )
            let displayFrame = mappingChoice.frame
            let displayFrameMappingSourceDescription = mappingChoice.mappingSourceDescription
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let configuration = SCStreamConfiguration()
            let maxDimension = CGFloat(1280)
            var pixelScale = CGFloat(filter.pointPixelScale)
            if pixelScale <= 0, let screen = nsscreenForDisplay {
                pixelScale = screen.backingScaleFactor
            }
            if pixelScale <= 0 {
                pixelScale = 2
            }
            let nativePixelWidth = contentRect.width * pixelScale
            let nativePixelHeight = contentRect.height * pixelScale
            let uniformScale = min(maxDimension / max(nativePixelWidth, 1), maxDimension / max(nativePixelHeight, 1))
            configuration.width = Int(max(1, round(nativePixelWidth * uniformScale)))
            configuration.height = Int(max(1, round(nativePixelHeight * uniformScale)))

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            // Use the bitmap’s real pixel dimensions for AI labels and for mapping clicks/pointer
            // back to screen space. `SCStreamConfiguration` width/height can differ slightly from
            // the returned `CGImage` (rounding, capture pipeline); using the wrong denominator
            // skews horizontal/vertical scale (often pushing tab clicks to the wrong column).
            let capturedPixelWidth = cgImage.width
            let capturedPixelHeight = cgImage.height

            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                continue
            }

            let screenLabel: String
            if sortedDisplays.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayFrame: displayFrame,
                displayFrameMappingSourceDescription: displayFrameMappingSourceDescription,
                screenshotWidthInPixels: capturedPixelWidth,
                screenshotHeightInPixels: capturedPixelHeight
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }
}
