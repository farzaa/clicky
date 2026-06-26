//
//  GroundingPointProjector.swift
//  leanring-buddy
//
//  Converts Vision screenshot coordinates into display coordinates without
//  deciding whether a Spider dot is safe.
//

import CoreGraphics

struct GroundingPointProjection {
    let capture: CompanionScreenCapture
    let screenshotPoint: CGPoint
    let displayPoint: CGPoint
}

enum GroundingPointProjector {
    static func projection(
        for guidePoint: SpiderGuidePoint,
        in screenCaptures: [CompanionScreenCapture]
    ) -> GroundingPointProjection? {
        let capture: CompanionScreenCapture? = {
            if let screenNumber = guidePoint.screenNumber,
               screenNumber >= 1,
               screenNumber <= screenCaptures.count {
                return screenCaptures[screenNumber - 1]
            }
            if guidePoint.screenNumber != nil {
                return nil
            }
            return screenCaptures.first(where: { $0.isCursorScreen })
        }()
        guard let capture else { return nil }

        let screenshotWidth = CGFloat(capture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(capture.screenshotHeightInPixels)
        let displayWidth = CGFloat(capture.displayWidthInPoints)
        let displayHeight = CGFloat(capture.displayHeightInPoints)
        let screenshotPoint = CGPoint(x: guidePoint.x, y: guidePoint.y)
        guard screenshotWidth > 0,
              screenshotHeight > 0,
              displayWidth > 0,
              displayHeight > 0,
              screenshotPoint.x.isFinite,
              screenshotPoint.y.isFinite,
              screenshotPoint.x >= 0,
              screenshotPoint.x <= screenshotWidth,
              screenshotPoint.y >= 0,
              screenshotPoint.y <= screenshotHeight else {
            return nil
        }

        let displayLocalX = screenshotPoint.x * (displayWidth / screenshotWidth)
        let displayLocalY = screenshotPoint.y * (displayHeight / screenshotHeight)
        let appKitY = displayHeight - displayLocalY
        return GroundingPointProjection(
            capture: capture,
            screenshotPoint: screenshotPoint,
            displayPoint: CGPoint(
                x: displayLocalX + capture.displayFrame.origin.x,
                y: appKitY + capture.displayFrame.origin.y
            )
        )
    }
}
