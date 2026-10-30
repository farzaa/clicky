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

@MainActor
enum CompanionScreenCaptureUtility {

    /// Captures displays as JPEG data based on the provided settings.
    ///
    /// - Parameters:
    ///   - captureOnlyPrimaryScreen: When true, only the screen containing the cursor is captured.
    ///   - captureActiveWindowOnly: When true, captures only the frontmost application window
    ///     instead of the full screen.
    ///   - jpegCompressionQuality: JPEG compression factor from 0.0 (max compression) to 1.0 (min compression).
    static func captureAllScreensAsJPEG(
        captureOnlyPrimaryScreen: Bool = false,
        captureActiveWindowOnly: Bool = false,
        jpegCompressionQuality: CGFloat = 0.8
    ) async throws -> [CompanionScreenCapture] {
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

        // If capturing only the active window, find the frontmost non-own window
        let activeWindow: SCWindow? = captureActiveWindowOnly
            ? content.windows.first(where: { window in
                window.owningApplication?.bundleIdentifier != ownBundleIdentifier
                    && window.isOnScreen
                    && window.frame.width > 100
                    && window.frame.height > 100
              })
            : nil

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            // Skip non-cursor screens when primary-only mode is enabled
            if captureOnlyPrimaryScreen && !isCursorScreen {
                continue
            }

            let filter: SCContentFilter
            if let activeWindow {
                // Capture just the active window — no desktop or other windows
                filter = SCContentFilter(desktopIndependentWindow: activeWindow)
            } else {
                filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)
            }

            let configuration = SCStreamConfiguration()
            let maxDimension = 1280

            if let activeWindow {
                // Size the capture to the window's actual dimensions, capped at maxDimension
                let windowWidth = Int(activeWindow.frame.width)
                let windowHeight = Int(activeWindow.frame.height)
                let windowAspectRatio = CGFloat(windowWidth) / CGFloat(windowHeight)
                if windowWidth >= windowHeight {
                    configuration.width = min(windowWidth, maxDimension)
                    configuration.height = Int(CGFloat(configuration.width) / windowAspectRatio)
                } else {
                    configuration.height = min(windowHeight, maxDimension)
                    configuration.width = Int(CGFloat(configuration.height) * windowAspectRatio)
                }
            } else {
                let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
                if display.width >= display.height {
                    configuration.width = maxDimension
                    configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
                } else {
                    configuration.height = maxDimension
                    configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
                }
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: jpegCompressionQuality]) else {
                continue
            }

            let screenLabel: String
            if captureActiveWindowOnly, let activeWindow {
                let appName = activeWindow.owningApplication?.applicationName ?? "unknown app"
                screenLabel = "active window (\(appName)) — cursor screen"
            } else if sortedDisplays.count == 1 || captureOnlyPrimaryScreen {
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

            // Only need one screen when capturing the active window
            if captureActiveWindowOnly {
                break
            }
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }
}
