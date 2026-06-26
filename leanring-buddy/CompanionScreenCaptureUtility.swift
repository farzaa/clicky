//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the Spider voice flow.
//  Keeps screenshot capture independent from panel and overlay state.
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

enum CompanionScreenCaptureError: Error {
    case noDisplayAvailable
    case noScreenCaptured
}

@MainActor
enum CompanionScreenCaptureUtility {
    private static let cursorScreenMaxDimension = 2048
    private static let secondaryScreenMaxDimension = 1280
    private static let minimumScreenMaxDimension = 896
    private static let maxTotalJPEGBytes = 5_200_000
    private static let maxScreenCaptures = SpiderContentLimits.maxGuideScreenshotCount
    private static let jpegCompressionFactors: [CGFloat] = [0.78, 0.68, 0.58]

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw CompanionScreenCaptureError.noDisplayAvailable
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
        var totalJPEGBytes = 0

        for (displayIndex, display) in sortedDisplays.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in SpiderCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)
            let remainingByteBudget = Self.maxTotalJPEGBytes - totalJPEGBytes
            guard remainingByteBudget > 0 else { break }
            let preferredMaxDimension = isCursorScreen
                ? Self.cursorScreenMaxDimension
                : Self.secondaryScreenMaxDimension
            guard let encodedCapture = try await captureJPEG(
                display: display,
                filter: filter,
                preferredMaxDimension: preferredMaxDimension,
                remainingByteBudget: remainingByteBudget
            ) else {
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

            let capture = CompanionScreenCapture(
                imageData: encodedCapture.jpegData,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: encodedCapture.pixelWidth,
                screenshotHeightInPixels: encodedCapture.pixelHeight
            )
            capturedScreens.append(capture)
            totalJPEGBytes += capture.imageData.count
            if capturedScreens.count >= Self.maxScreenCaptures {
                break
            }
        }

        guard !capturedScreens.isEmpty else {
            throw CompanionScreenCaptureError.noScreenCaptured
        }

        return capturedScreens
    }

    private struct EncodedCapture {
        let jpegData: Data
        let pixelWidth: Int
        let pixelHeight: Int
    }

    private static func captureJPEG(
        display: SCDisplay,
        filter: SCContentFilter,
        preferredMaxDimension: Int,
        remainingByteBudget: Int
    ) async throws -> EncodedCapture? {
        for maxDimension in maxDimensions(startingAt: preferredMaxDimension) {
            let configuration = configuration(for: display, maxDimension: maxDimension)
            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            for compressionFactor in jpegCompressionFactors {
                guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: compressionFactor]) else {
                    continue
                }

                guard jpegData.count <= remainingByteBudget else {
                    continue
                }

                return EncodedCapture(
                    jpegData: jpegData,
                    pixelWidth: cgImage.width,
                    pixelHeight: cgImage.height
                )
            }
        }

        return nil
    }

    private static func maxDimensions(startingAt preferredMaxDimension: Int) -> [Int] {
        var dimensions: [Int] = []
        var nextDimension = preferredMaxDimension

        while nextDimension >= minimumScreenMaxDimension {
            dimensions.append(nextDimension)
            nextDimension -= 256
        }

        if dimensions.last != minimumScreenMaxDimension {
            dimensions.append(minimumScreenMaxDimension)
        }

        return dimensions
    }

    private static func configuration(for display: SCDisplay, maxDimension: Int) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let aspectRatio = CGFloat(display.width) / CGFloat(display.height)

        if display.width >= display.height {
            configuration.width = maxDimension
            configuration.height = max(1, Int(CGFloat(maxDimension) / aspectRatio))
        } else {
            configuration.height = maxDimension
            configuration.width = max(1, Int(CGFloat(maxDimension) * aspectRatio))
        }

        return configuration
    }
}
