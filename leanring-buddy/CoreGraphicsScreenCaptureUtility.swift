//
//  CoreGraphicsScreenCaptureUtility.swift
//  leanring-buddy
//
//  Captures the screen with CGWindowListCreateImage instead of ScreenCaptureKit.
//  On macOS Tahoe, ScreenCaptureKit screenshot/stream APIs route through
//  screencaptureui and show the floating screenshot thumbnail popup.
//

import AppKit
import CoreGraphics
import Darwin

struct CoreGraphicsScreenJPEGCapture {
  let imageData: Data
  let screenshotWidthInPixels: Int
  let screenshotHeightInPixels: Int
}

enum CoreGraphicsScreenCaptureUtility {
  static func captureScreenAsJPEG(
    screen: NSScreen,
    belowWindowID: CGWindowID?,
    maxDimension: Int
  ) -> CoreGraphicsScreenJPEGCapture? {
    let quartzCaptureFrame = screen.quartzCaptureFrame
    let captureOptions: CGWindowListOption = belowWindowID == nil
      ? .optionOnScreenOnly
      : .optionOnScreenBelowWindow
    let referenceWindowID = belowWindowID ?? kCGNullWindowID

    guard let capturedImage = LegacyCoreGraphicsWindowCapture.createImage(
      in: quartzCaptureFrame,
      listOption: captureOptions,
      windowID: referenceWindowID,
      imageOptions: [.bestResolution, .boundsIgnoreFraming]
    ) else {
      return nil
    }

    guard let resizedImage = resizeImage(capturedImage, maxDimension: maxDimension),
          let jpegData = NSBitmapImageRep(cgImage: resizedImage)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
      return nil
    }

    return CoreGraphicsScreenJPEGCapture(
      imageData: jpegData,
      screenshotWidthInPixels: resizedImage.width,
      screenshotHeightInPixels: resizedImage.height
    )
  }

  static func topmostOwnedWindowID(on screen: NSScreen) -> CGWindowID? {
    let visibleOwnedWindows = NSApp.windows.filter { window in
      window.isVisible
        && window.alphaValue > 0
        && screen.frame.intersects(window.frame)
    }

    guard let topmostOwnedWindow = visibleOwnedWindows.max(by: { $0.windowNumber < $1.windowNumber }) else {
      return nil
    }

    // NSWindow.windowNumber is an Int that can be negative or exceed UInt32 on
    // recent macOS (e.g. status bar windows), so convert safely instead of
    // force-trapping with the non-failable CGWindowID initializer.
    guard topmostOwnedWindow.windowNumber > 0,
          let topmostOwnedWindowID = CGWindowID(exactly: topmostOwnedWindow.windowNumber) else {
      return nil
    }

    return topmostOwnedWindowID
  }

  static func canCaptureAnyScreen(maxDimension: Int = 64) -> Bool {
    guard let screen = NSScreen.main ?? NSScreen.screens.first else { return false }
    return captureScreenAsJPEG(
      screen: screen,
      belowWindowID: topmostOwnedWindowID(on: screen),
      maxDimension: maxDimension
    ) != nil
  }

  private static func resizeImage(_ image: CGImage, maxDimension: Int) -> CGImage? {
    let sourceWidth = image.width
    let sourceHeight = image.height
    guard sourceWidth > 0, sourceHeight > 0 else { return nil }

    let aspectRatio = CGFloat(sourceWidth) / CGFloat(sourceHeight)
    let targetWidth: Int
    let targetHeight: Int

    if sourceWidth >= sourceHeight {
      targetWidth = maxDimension
      targetHeight = max(1, Int(CGFloat(maxDimension) / aspectRatio))
    } else {
      targetHeight = maxDimension
      targetWidth = max(1, Int(CGFloat(maxDimension) * aspectRatio))
    }

    guard let context = CGContext(
      data: nil,
      width: targetWidth,
      height: targetHeight,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      return nil
    }

    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
    return context.makeImage()
  }
}

/// Runtime wrapper around CGWindowListCreateImage. The symbol is marked
/// unavailable in the macOS 15 SDK, but it still works and does not route
/// through Tahoe's screencaptureui floating thumbnail.
private enum LegacyCoreGraphicsWindowCapture {
  private typealias CGWindowListCreateImageFunction = @convention(c) (
    CGRect,
    CGWindowListOption,
    CGWindowID,
    CGWindowImageOption
  ) -> Unmanaged<CGImage>?

  private static let createImageFunction: CGWindowListCreateImageFunction? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
      return nil
    }
    return unsafeBitCast(symbol, to: CGWindowListCreateImageFunction.self)
  }()

  static func createImage(
    in screenBounds: CGRect,
    listOption: CGWindowListOption,
    windowID: CGWindowID,
    imageOptions: CGWindowImageOption
  ) -> CGImage? {
    createImageFunction?(screenBounds, listOption, windowID, imageOptions)?.takeRetainedValue()
  }
}

private extension NSScreen {
  var quartzCaptureFrame: CGRect {
    let screenFrame = frame
    guard let primaryScreen = NSScreen.screens.first else { return screenFrame }
    return CGRect(
      x: screenFrame.origin.x,
      y: primaryScreen.frame.height - screenFrame.origin.y - screenFrame.height,
      width: screenFrame.width,
      height: screenFrame.height
    )
  }
}
