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
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
}

enum CompanionScreenCaptureFallbackPreference {
    private static let shouldPreferCoreGraphicsCaptureUserDefaultsKey = "com.learningbuddy.shouldPreferCoreGraphicsScreenCapture"

    static var shouldPreferCoreGraphicsCapture: Bool {
        UserDefaults.standard.bool(forKey: shouldPreferCoreGraphicsCaptureUserDefaultsKey)
    }

    static func rememberScreenCaptureKitNeedsFallback() {
        UserDefaults.standard.set(true, forKey: shouldPreferCoreGraphicsCaptureUserDefaultsKey)
    }
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        if CompanionScreenCaptureFallbackPreference.shouldPreferCoreGraphicsCapture {
            DotDebugLogger.log("screen.capture", "using CoreGraphics fallback by preference")
            return try captureAllScreensWithCoreGraphicsFallback(screenCaptureKitError: nil)
        }

        do {
            return try await captureAllScreensWithScreenCaptureKit()
        } catch {
            DotDebugLogger.log("screen.capture", "ScreenCaptureKit capture failed; trying CoreGraphics fallback", metadata: [
                "error": error.localizedDescription
            ])
            CompanionScreenCaptureFallbackPreference.rememberScreenCaptureKitNeedsFallback()
            return try captureAllScreensWithCoreGraphicsFallback(screenCaptureKitError: error)
        }
    }

    private static func captureAllScreensWithScreenCaptureKit() async throws -> [CompanionScreenCapture] {
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
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            let maxDimension = 1280
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                configuration.width = maxDimension
                configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
            } else {
                configuration.height = maxDimension
                configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

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
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: configuration.width,
                screenshotHeightInPixels: configuration.height
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }

    private static func captureAllScreensWithCoreGraphicsFallback(screenCaptureKitError: Error?) throws -> [CompanionScreenCapture] {
        let mouseLocation = NSEvent.mouseLocation
        let screensWithDisplayIDs = NSScreen.screens.compactMap { screen -> (screen: NSScreen, displayID: CGDirectDisplayID)? in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
                return nil
            }
            return (screen: screen, displayID: screenNumber)
        }

        let sortedScreens = screensWithDisplayIDs.sorted { firstScreen, secondScreen in
            let firstContainsCursor = firstScreen.screen.frame.contains(mouseLocation)
            let secondContainsCursor = secondScreen.screen.frame.contains(mouseLocation)
            if firstContainsCursor != secondContainsCursor { return firstContainsCursor }
            return false
        }

        var capturedScreens: [CompanionScreenCapture] = []
        for (screenIndex, screenWithDisplayID) in sortedScreens.enumerated() {
            guard let fullSizeImage = CGDisplayCreateImage(screenWithDisplayID.displayID),
                  let resizedJPEG = resizedJPEGData(from: fullSizeImage, maxDimension: 1280) else {
                continue
            }

            let displayFrame = screenWithDisplayID.screen.frame
            let isCursorScreen = displayFrame.contains(mouseLocation)
            let screenLabel: String
            if sortedScreens.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(screenIndex + 1) of \(sortedScreens.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(screenIndex + 1) of \(sortedScreens.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: resizedJPEG.data,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: resizedJPEG.width,
                screenshotHeightInPixels: resizedJPEG.height
            ))
        }

        guard !capturedScreens.isEmpty else {
            if let screenCaptureKitError {
                throw screenCaptureKitError
            }
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen with CoreGraphics fallback"]
            )
        }

        DotDebugLogger.log("screen.capture", "CoreGraphics fallback captured screens", metadata: [
            "count": capturedScreens.count
        ])
        return capturedScreens
    }

    private static func resizedJPEGData(from image: CGImage, maxDimension: Int) -> (data: Data, width: Int, height: Int)? {
        let originalWidth = image.width
        let originalHeight = image.height
        let largestOriginalDimension = max(originalWidth, originalHeight)
        let scale = min(1.0, Double(maxDimension) / Double(largestOriginalDimension))
        let targetWidth = max(1, Int(Double(originalWidth) * scale))
        let targetHeight = max(1, Int(Double(originalHeight) * scale))

        let resizedImage: CGImage
        if targetWidth == originalWidth && targetHeight == originalHeight {
            resizedImage = image
        } else {
            guard let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else {
                return nil
            }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            guard let renderedImage = context.makeImage() else {
                return nil
            }
            resizedImage = renderedImage
        }

        guard let jpegData = NSBitmapImageRep(cgImage: resizedImage)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return nil
        }

        return (data: jpegData, width: targetWidth, height: targetHeight)
    }
}
