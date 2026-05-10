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

/// Errors emitted by the screen capture utility. Distinguishing the
/// "permission denied" case from generic failures lets the caller surface
/// a relaunch / re-grant UI instead of a vague error.
enum CompanionScreenCaptureError: Error {
    case permissionDenied(underlying: Error)
    case noDisplaysAvailable
    case captureProducedNoImages
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen.
    ///
    /// Uses ScreenCaptureKit exclusively. The previous CoreGraphics fallback
    /// has been removed because:
    ///   1. `CGDisplayCreateImage` is obsoleted on macOS 15.0+ and silently
    ///      returns the desktop wallpaper layer (instead of the fullscreen
    ///      app's content) when the active Space is a fullscreen-app Space
    ///      or when SCK permission is missing.
    ///   2. macOS 15 (Sequoia) introduced a separate per-app approval state
    ///      for ScreenCaptureKit that the legacy CG APIs are blind to. A
    ///      fallback that "succeeds" with bogus pixels masks the real
    ///      permission problem and prevents the user from being told to
    ///      re-grant + relaunch.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        do {
            return try await captureAllScreensWithScreenCaptureKit()
        } catch {
            if Self.isPermissionDeniedError(error) {
                DotDebugLogger.log("screen.capture", "ScreenCaptureKit denied by TCC", metadata: [
                    "error": error.localizedDescription
                ])
                throw CompanionScreenCaptureError.permissionDenied(underlying: error)
            }
            DotDebugLogger.log("screen.capture", "ScreenCaptureKit capture failed", metadata: [
                "error": error.localizedDescription
            ])
            throw error
        }
    }

    /// Returns true when the error indicates the macOS Screen & System Audio
    /// Recording permission is not granted to this app. ScreenCaptureKit
    /// surfaces denial as either an SCStreamError with code .userDeclined or
    /// a plain NSError whose localized description contains "declined TCCs".
    /// Both shapes are checked because the wrapper varies by macOS version.
    static func isPermissionDeniedError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == SCStreamError.errorDomain,
           let code = SCStreamError.Code(rawValue: nsError.code),
           code == .userDeclined {
            return true
        }
        let lowercaseDescription = nsError.localizedDescription.lowercased()
        if lowercaseDescription.contains("declined tccs")
            || lowercaseDescription.contains("user declined")
            || lowercaseDescription.contains("not authorized") {
            return true
        }
        return false
    }

    private static func captureAllScreensWithScreenCaptureKit() async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw CompanionScreenCaptureError.noDisplaysAvailable
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
            throw CompanionScreenCaptureError.captureProducedNoImages
        }

        return capturedScreens
    }
}
