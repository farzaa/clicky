//
//  MacOSScreenshotFloatingThumbnailDismisser.swift
//  leanring-buddy
//
//  macOS Tahoe keeps screencaptureui alive and shows floating screenshot
//  thumbnails when ScreenCaptureKit takes captures. Clicky now captures via
//  Core Graphics, but we still tear down leftover thumbnail UI if it appears.
//

import Foundation

enum MacOSScreenshotFloatingThumbnailDismisser {
  private static let screencaptureUIProcessNames = [
    "screencaptureui",
  ]

  static func dismissIfNeeded() {
    for processName in screencaptureUIProcessNames {
      terminateProcess(named: processName)
    }
  }

  static func cleanupTemporaryScreenshotArtifacts() {
    let temporaryItemsDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("TemporaryItems", isDirectory: true)

    guard let temporaryItemURLs = try? FileManager.default.contentsOfDirectory(
      at: temporaryItemsDirectory,
      includingPropertiesForKeys: nil
    ) else {
      return
    }

    for temporaryItemURL in temporaryItemURLs where temporaryItemURL.lastPathComponent
      .localizedCaseInsensitiveContains("screencaptureui") {
      try? FileManager.default.removeItem(at: temporaryItemURL)
    }

    scheduleFollowUpDismissal()
  }

  private static func scheduleFollowUpDismissal() {
    Task {
      for _ in 0..<3 {
        try? await Task.sleep(nanoseconds: 150_000_000)
        dismissIfNeeded()
      }
    }
  }

  private static func terminateProcess(named processName: String) {
    let terminateProcess = Process()
    terminateProcess.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
    terminateProcess.arguments = ["-9", processName]
    try? terminateProcess.run()
    terminateProcess.waitUntilExit()
  }
}
