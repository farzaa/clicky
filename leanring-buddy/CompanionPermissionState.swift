//
//  CompanionPermissionState.swift
//  leanring-buddy
//
//  Typed permission state and transition rules for the companion lifecycle.
//  This keeps diagnostics and analytics event names bounded and testable.
//

import Foundation

enum CompanionPermissionKind: String, CaseIterable, Equatable {
    case accessibility
    case screenRecording = "screen_recording"
    case microphone
    case screenContent = "screen_content"

    var telemetryName: SpiderPermissionTelemetryName {
        switch self {
        case .accessibility:
            return .accessibility
        case .screenRecording:
            return .screenRecording
        case .microphone:
            return .microphone
        case .screenContent:
            return .screenContent
        }
    }

    var diagnosticFlagKey: CompanionPermissionDiagnosticFlagKey {
        switch self {
        case .accessibility:
            return .accessibility
        case .screenRecording:
            return .screenRecording
        case .microphone:
            return .microphone
        case .screenContent:
            return .screenContent
        }
    }
}

enum CompanionPermissionDiagnosticFlagKey: String, Equatable {
    case accessibility = "permission_accessibility"
    case screenRecording = "permission_screen_recording"
    case microphone = "permission_microphone"
    case screenContent = "permission_screen_content"

    var diagnosticName: String {
        rawValue
    }

    var staticName: StaticString {
        switch self {
        case .accessibility:
            return "permission_accessibility"
        case .screenRecording:
            return "permission_screen_recording"
        case .microphone:
            return "permission_microphone"
        case .screenContent:
            return "permission_screen_content"
        }
    }
}

struct CompanionPermissionState: Equatable {
    let hasAccessibility: Bool
    let hasScreenRecording: Bool
    let hasMicrophone: Bool
    let hasScreenContent: Bool

    var allRequiredGranted: Bool {
        hasAccessibility && hasScreenRecording && hasMicrophone && hasScreenContent
    }
}

struct CompanionPermissionDiagnosticFlag: Equatable {
    let key: CompanionPermissionDiagnosticFlagKey
    let value: Bool
}

struct CompanionPermissionTransition: Equatable {
    let previous: CompanionPermissionState
    let current: CompanionPermissionState

    var didPromptPermissionStateChange: Bool {
        previous.hasAccessibility != current.hasAccessibility
            || previous.hasScreenRecording != current.hasScreenRecording
            || previous.hasMicrophone != current.hasMicrophone
    }

    var newlyGrantedPromptPermissions: [CompanionPermissionKind] {
        var permissions: [CompanionPermissionKind] = []

        if !previous.hasAccessibility && current.hasAccessibility {
            permissions.append(.accessibility)
        }
        if !previous.hasScreenRecording && current.hasScreenRecording {
            permissions.append(.screenRecording)
        }
        if !previous.hasMicrophone && current.hasMicrophone {
            permissions.append(.microphone)
        }

        return permissions
    }

    var didBecomeFullyGranted: Bool {
        !previous.allRequiredGranted && current.allRequiredGranted
    }
}

enum CompanionPermissionPolicy {
    static func transition(
        from previous: CompanionPermissionState,
        to current: CompanionPermissionState
    ) -> CompanionPermissionTransition {
        CompanionPermissionTransition(previous: previous, current: current)
    }

    static func screenGuidancePermissionsReady(
        hasScreenContentPermission: Bool,
        shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch: Bool
    ) -> Bool {
        hasScreenContentPermission
            && shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch
    }

    static func diagnosticFlags(for state: CompanionPermissionState) -> [CompanionPermissionDiagnosticFlag] {
        [
            CompanionPermissionDiagnosticFlag(
                key: CompanionPermissionKind.accessibility.diagnosticFlagKey,
                value: state.hasAccessibility
            ),
            CompanionPermissionDiagnosticFlag(
                key: CompanionPermissionKind.screenRecording.diagnosticFlagKey,
                value: state.hasScreenRecording
            ),
            CompanionPermissionDiagnosticFlag(
                key: CompanionPermissionKind.microphone.diagnosticFlagKey,
                value: state.hasMicrophone
            ),
            CompanionPermissionDiagnosticFlag(
                key: CompanionPermissionKind.screenContent.diagnosticFlagKey,
                value: state.hasScreenContent
            ),
        ]
    }

    static func promptPermissionGrantTelemetryNames(
        for transition: CompanionPermissionTransition
    ) -> [SpiderPermissionTelemetryName] {
        transition.newlyGrantedPromptPermissions.map(\.telemetryName)
    }
}
