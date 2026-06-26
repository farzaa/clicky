//
//  CompanionInteractionReadinessPolicy.swift
//  leanring-buddy
//
//  Pure readiness decisions for user-triggered companion interactions. The
//  manager owns UI side effects; this policy only classifies the gate.
//

import Foundation

enum CompanionInteractionReadinessPolicy {
    enum Decision: Equatable {
        case ready
        case accountBlocked
        case permissionsBlocked
        case screenGuidanceBlocked

        var isReady: Bool {
            self == .ready
        }
    }

    static func fullPermissionReadiness(
        accountCanUseAI: Bool,
        allPermissionsGranted: Bool
    ) -> Decision {
        guard accountCanUseAI else { return .accountBlocked }
        guard allPermissionsGranted else { return .permissionsBlocked }
        return .ready
    }

    static func accountReadiness(accountCanUseAI: Bool) -> Decision {
        accountCanUseAI ? .ready : .accountBlocked
    }

    static func screenGuidancePermissionReadiness(
        hasScreenGuidancePermissions: Bool
    ) -> Decision {
        hasScreenGuidancePermissions ? .ready : .screenGuidanceBlocked
    }
}
