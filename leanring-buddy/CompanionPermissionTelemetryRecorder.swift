//
//  CompanionPermissionTelemetryRecorder.swift
//  leanring-buddy
//
//  Emits bounded permission diagnostics and analytics from typed permission contracts.
//

enum CompanionPermissionTelemetryRecorder {
    static func recordDiagnosticFlags(for state: CompanionPermissionState) {
        for flag in CompanionPermissionPolicy.diagnosticFlags(for: state) {
            SpiderDiagnostics.flag(flag.key.staticName, flag.value)
        }
    }

    static func recordPromptPermissionChange(
        for transition: CompanionPermissionTransition,
        currentState: CompanionPermissionState
    ) {
        guard transition.didPromptPermissionStateChange else { return }
        recordDiagnosticFlags(for: currentState)
    }

    static func recordPromptPermissionGrantEvents(for transition: CompanionPermissionTransition) {
        for permission in transition.newlyGrantedPromptPermissions {
            recordPermissionGranted(permission)
        }
    }

    static func recordPermissionGranted(_ permission: CompanionPermissionKind) {
        SpiderAnalytics.trackPermissionGranted(permission.telemetryName)
    }

    static func recordScreenContentCaptureProbe(width: Int, height: Int, didCapture: Bool) {
        SpiderDiagnostics.count("screen_content_capture_width", width)
        SpiderDiagnostics.count("screen_content_capture_height", height)
        SpiderDiagnostics.flag("screen_content_did_capture", didCapture)
    }

    static func recordAllPermissionsGrantedIfNeeded(for transition: CompanionPermissionTransition) {
        guard transition.didBecomeFullyGranted else { return }
        SpiderAnalytics.trackAllPermissionsGranted()
    }
}
