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

    private struct ShareableContentContext {
        let sortedDisplays: [SCDisplay]
        let nsScreenByDisplayID: [CGDirectDisplayID: NSScreen]
        let ownAppWindows: [SCWindow]
        let mouseLocation: CGPoint
    }

    /// Shared setup: SC shareable content, windows to exclude, NSScreen map, cursor-first display order.
    private static func makeShareableContentContext() async throws -> ShareableContentContext {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        return ShareableContentContext(
            sortedDisplays: sortedDisplays,
            nsScreenByDisplayID: nsScreenByDisplayID,
            ownAppWindows: ownAppWindows,
            mouseLocation: mouseLocation
        )
    }

    /// Captures one display as JPEG; returns nil if JPEG encoding fails.
    /// When `totalDisplayCount` is 1, the label is always the single-screen cursor line (used for cursor-only vision).
    private static func captureDisplayAsJPEG(
        display: SCDisplay,
        displayIndex: Int,
        totalDisplayCount: Int,
        context: ShareableContentContext
    ) async throws -> CompanionScreenCapture? {
        let filter = SCContentFilter(display: display, excludingWindows: context.ownAppWindows)
        filter.includeMenuBar = true

        let nsscreenForDisplay = context.nsScreenByDisplayID[display.displayID]
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
        let mouseLocation = context.mouseLocation
        let isCursorScreen = displayFrame.contains(mouseLocation)

        let screenLabel: String
        if totalDisplayCount == 1 {
            screenLabel = "user's screen (cursor is here)"
        } else if isCursorScreen {
            screenLabel = "screen \(displayIndex + 1) of \(totalDisplayCount) — cursor is on this screen (primary focus)"
        } else {
            screenLabel = "screen \(displayIndex + 1) of \(totalDisplayCount) — secondary screen"
        }

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

        let capturedPixelWidth = cgImage.width
        let capturedPixelHeight = cgImage.height

        guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return nil
        }

        return CompanionScreenCapture(
            imageData: jpegData,
            label: screenLabel,
            isCursorScreen: isCursorScreen,
            displayFrame: displayFrame,
            displayFrameMappingSourceDescription: displayFrameMappingSourceDescription,
            screenshotWidthInPixels: capturedPixelWidth,
            screenshotHeightInPixels: capturedPixelHeight
        )
    }

    /// Vision-only capture: the display that currently contains the cursor (matches push-to-talk “active” workspace).
    static func captureCursorScreenAsJPEG() async throws -> [CompanionScreenCapture] {
        let context = try await makeShareableContentContext()
        let mouseLocation = context.mouseLocation

        let targetDisplay: SCDisplay = {
            for display in context.sortedDisplays {
                let frame = context.nsScreenByDisplayID[display.displayID]?.frame ?? display.frame
                if frame.contains(mouseLocation) {
                    return display
                }
            }
            return context.sortedDisplays[0]
        }()

        guard let capture = try await captureDisplayAsJPEG(
            display: targetDisplay,
            displayIndex: 0,
            totalDisplayCount: 1,
            context: context
        ) else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture cursor screen"])
        }

        return [capture]
    }

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        let context = try await makeShareableContentContext()
        let sortedDisplays = context.sortedDisplays
        let totalDisplayCount = sortedDisplays.count

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            if let one = try await captureDisplayAsJPEG(
                display: display,
                displayIndex: displayIndex,
                totalDisplayCount: totalDisplayCount,
                context: context
            ) {
                capturedScreens.append(one)
            }
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }
}
