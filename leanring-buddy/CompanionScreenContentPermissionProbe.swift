//
//  CompanionScreenContentPermissionProbe.swift
//  leanring-buddy
//
//  Isolated ScreenCaptureKit permission probe. It returns only capture
//  dimensions so no screenshot content can leak into app state or telemetry.
//

import Foundation
import ScreenCaptureKit

struct CompanionScreenContentPermissionProbeResult: Equatable {
    let width: Int
    let height: Int

    var didCapture: Bool {
        width > 0 && height > 0
    }
}

enum CompanionScreenContentPermissionProbeOutcome: Equatable {
    case completed(CompanionScreenContentPermissionProbeResult)
    case noDisplayAvailable
}

enum CompanionScreenContentPermissionProbe {
    typealias Capture = () async throws -> CompanionScreenContentPermissionProbeOutcome

    static func run(
        capture: Capture = captureViaScreenCaptureKit
    ) async throws -> CompanionScreenContentPermissionProbeOutcome {
        try await capture()
    }

    private static func captureViaScreenCaptureKit() async throws -> CompanionScreenContentPermissionProbeOutcome {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { return .noDisplayAvailable }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 320
        configuration.height = 240

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        return .completed(CompanionScreenContentPermissionProbeResult(
            width: image.width,
            height: image.height
        ))
    }
}
