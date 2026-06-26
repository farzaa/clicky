//
//  CompanionManagerDebugActions.swift
//  leanring-buddy
//
//  Debug-only companion actions kept out of the production state manager body.
//

#if DEBUG
import AppKit
import Foundation

@MainActor
extension CompanionManager {
    func previewMissionPointerOverlay() {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let targetScreen else { return }

        let screenFrame = targetScreen.frame
        let direction = adMission.campaignDirection
        let objective = direction?.recommendedObjective.spiderSanitizedSingleLine(
            maxCharacters: SpiderContentLimits.maxGuidePointLabelCharacters
        )
        let missionAlignment = direction?.whyThisObjective.spiderSanitizedSingleLine(
            maxCharacters: SpiderContentLimits.maxGuidePointMissionAlignmentCharacters
        )

        clearDetectedElementLocation()
        transientOverlayHideController.cancelPendingHide()

        if !isSpiderCursorEnabled {
            isSpiderCursorEnabled = true
            UserDefaults.standard.set(true, forKey: "isSpiderCursorEnabled")
        }

        overlayWindowManager.hasShownOverlayBefore = true
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        setOverlayVisible(true)

        detectedElementBubbleText = "Click here."
        detectedElementPointLabel = objective?.isEmpty == false ? objective : "Mission target"
        detectedElementMissionAlignment = missionAlignment?.isEmpty == false
            ? missionAlignment
            : "Matches the selected Ad Mission."
        detectedElementDisplayFrame = screenFrame
        detectedElementScreenLocation = CGPoint(
            x: screenFrame.midX,
            y: screenFrame.midY
        )
        detectedElementTargetRevision = UUID()
        SpiderDiagnostics.event("debug mission pointer preview shown")
    }
}
#endif
