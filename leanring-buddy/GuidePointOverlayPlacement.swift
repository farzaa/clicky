//
//  GuidePointOverlayPlacement.swift
//  leanring-buddy
//
//  Pure coordinate conversion for accepted guide points. Safety gates decide
//  whether a point may exist before this layer runs.
//

import CoreGraphics
import Foundation

struct GuidePointOverlayPlacement: Equatable {
    let bubbleText: String
    let pointLabel: String?
    let missionAlignment: String?
    let screenLocation: CGPoint
    let displayFrame: CGRect
}

enum GuidePointOverlayPlacementRejection: Equatable {
    case targetScreenUnavailable
    case pointOutsideScreenshot
}

enum GuidePointOverlayPlacementResult: Equatable {
    case accepted(GuidePointOverlayPlacement)
    case rejected(GuidePointOverlayPlacementRejection)
}

enum GuidePointOverlayPlacementCalculator {
    static func placement(
        for guidePoint: SpiderGuidePoint,
        screenCaptures: [CompanionScreenCapture],
        bubbleText: String
    ) -> GuidePointOverlayPlacementResult {
        guard let targetScreenCapture = targetScreenCapture(for: guidePoint, screenCaptures: screenCaptures) else {
            return .rejected(.targetScreenUnavailable)
        }

        let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
        let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
        let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
        let targetX = CGFloat(guidePoint.x)
        let targetY = CGFloat(guidePoint.y)

        guard screenshotWidth > 0,
              screenshotHeight > 0,
              displayWidth > 0,
              displayHeight > 0,
              targetX.isFinite,
              targetY.isFinite,
              targetX >= 0,
              targetX <= screenshotWidth,
              targetY >= 0,
              targetY <= screenshotHeight else {
            return .rejected(.pointOutsideScreenshot)
        }

        let displayLocalX = targetX * (displayWidth / screenshotWidth)
        let displayLocalY = targetY * (displayHeight / screenshotHeight)
        let appKitY = displayHeight - displayLocalY
        let displayFrame = targetScreenCapture.displayFrame

        return .accepted(GuidePointOverlayPlacement(
            bubbleText: bubbleText.spiderSanitizedShortDialogue(
                maxCharacters: 64,
                maxWords: 8,
                maxSentences: 1
            ),
            pointLabel: guidePoint.label?.spiderSanitizedSingleLine(
                maxCharacters: SpiderContentLimits.maxGuidePointLabelCharacters
            ),
            missionAlignment: guidePoint.missionAlignment?.spiderSanitizedSingleLine(
                maxCharacters: SpiderContentLimits.maxGuidePointMissionAlignmentCharacters
            ),
            screenLocation: CGPoint(
                x: displayLocalX + displayFrame.origin.x,
                y: appKitY + displayFrame.origin.y
            ),
            displayFrame: displayFrame
        ))
    }

    private static func targetScreenCapture(
        for guidePoint: SpiderGuidePoint,
        screenCaptures: [CompanionScreenCapture]
    ) -> CompanionScreenCapture? {
        if let screenNumber = guidePoint.screenNumber,
           screenNumber >= 1,
           screenNumber <= screenCaptures.count {
            return screenCaptures[screenNumber - 1]
        } else if guidePoint.screenNumber != nil {
            return nil
        }

        return screenCaptures.first(where: { $0.isCursorScreen })
    }
}
