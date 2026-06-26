//
//  CompanionManagerCursorActions.swift
//  leanring-buddy
//
//  Cursor overlay visibility actions for CompanionManager.
//

import AppKit
import Foundation

@MainActor
extension CompanionManager {
    func setSpiderCursorEnabled(_ enabled: Bool) {
        isSpiderCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isSpiderCursorEnabled")
        transientOverlayHideController.cancelPendingHide()

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            setOverlayVisible(true)
        } else {
            overlayWindowManager.hideOverlay()
            setOverlayVisible(false)
        }
    }

    func showSpiderCursorForGuidedSetupIfPossible() {
        refreshAllPermissions()

        guard CompanionInteractionReadinessPolicy.accountReadiness(
            accountCanUseAI: accountState.canUseAI
        ).isReady else { return }
        guard CompanionInteractionReadinessPolicy.screenGuidancePermissionReadiness(
            hasScreenGuidancePermissions: hasScreenGuidancePermissions
        ).isReady else { return }

        if !isSpiderCursorEnabled {
            isSpiderCursorEnabled = true
            UserDefaults.standard.set(true, forKey: "isSpiderCursorEnabled")
        }

        transientOverlayHideController.cancelPendingHide()
        overlayWindowManager.hasShownOverlayBefore = true
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        setOverlayVisible(true)
    }
}
