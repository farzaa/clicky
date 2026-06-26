//
//  CompanionGuidePointOverlayPresenter.swift
//  leanring-buddy
//
//  Converts an already-approved guide point placement into CompanionManager
//  overlay state. Safety gates decide whether the point may exist before this
//  layer runs.
//

import CoreGraphics
import Foundation

struct CompanionGuidePointOverlayState: Equatable {
    let bubbleText: String
    let pointLabel: String?
    let missionAlignment: String?
    let screenLocation: CGPoint
    let displayFrame: CGRect
    let targetRevision: UUID
}

enum CompanionGuidePointOverlayApplication: Equatable {
    case accepted(CompanionGuidePointOverlayState)
    case rejected(GuidePointOverlayPlacementRejection)
}

enum CompanionGuidePointOverlayPresenter {
    static func application(
        for guidePoint: SpiderGuidePoint,
        screenCaptures: [CompanionScreenCapture],
        bubbleText: String,
        makeTargetRevision: () -> UUID = UUID.init
    ) -> CompanionGuidePointOverlayApplication {
        switch GuidePointOverlayPlacementCalculator.placement(
            for: guidePoint,
            screenCaptures: screenCaptures,
            bubbleText: bubbleText
        ) {
        case .accepted(let placement):
            return .accepted(CompanionGuidePointOverlayState(
                bubbleText: placement.bubbleText,
                pointLabel: placement.pointLabel,
                missionAlignment: placement.missionAlignment,
                screenLocation: placement.screenLocation,
                displayFrame: placement.displayFrame,
                targetRevision: makeTargetRevision()
            ))
        case .rejected(let rejection):
            return .rejected(rejection)
        }
    }

    static func diagnosticEvent(for rejection: GuidePointOverlayPlacementRejection) -> StaticString {
        switch rejection {
        case .targetScreenUnavailable:
            return "guide point ignored because target screen was unavailable"
        case .pointOutsideScreenshot:
            return "guide point ignored because coordinates were outside screenshot"
        }
    }
}
