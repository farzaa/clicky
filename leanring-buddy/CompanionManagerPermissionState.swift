//
//  CompanionManagerPermissionState.swift
//  leanring-buddy
//
//  Derived permission state exposed by CompanionManager.
//

import Foundation

@MainActor
extension CompanionManager {
    var allPermissionsGranted: Bool {
        companionPermissionState.allRequiredGranted
    }

    var hasScreenGuidancePermissions: Bool {
        CompanionPermissionPolicy.screenGuidancePermissionsReady(
            hasScreenContentPermission: hasScreenContentPermission,
            shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch: WindowPositionManager
                .shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch()
        )
    }

    var companionPermissionState: CompanionPermissionState {
        CompanionPermissionState(
            hasAccessibility: hasAccessibilityPermission,
            hasScreenRecording: hasScreenRecordingPermission,
            hasMicrophone: hasMicrophonePermission,
            hasScreenContent: hasScreenContentPermission
        )
    }
}
