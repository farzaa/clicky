//
//  AdMissionLifecyclePolicy.swift
//  leanring-buddy
//
//  Local Ad Mission lifecycle transitions kept outside CompanionManager.
//

import Foundation

enum AdMissionLifecyclePolicy {
    static func guidedSetupStarted(_ mission: AdMission, platformDisplayName: String) -> AdMission {
        var updatedMission = mission
        updatedMission.status = .guidedSetup
        updatedMission.decisions = AdMissionUpdateApplier.mergedList(updatedMission.decisions, with: [
            "Guided setup started for \(platformDisplayName). \(SpiderProductFeatures.mvpLockedReviewSchedule)",
        ])
        return updatedMission.sanitizedForLocalStorage()
    }

    static func preflightAuditRequested(_ mission: AdMission) -> AdMission {
        var updatedMission = mission
        updatedMission.status = .preflightNeeded
        return updatedMission.sanitizedForLocalStorage()
    }

    static func manuallyPublished(_ mission: AdMission) -> AdMission {
        var updatedMission = mission
        updatedMission.status = .publishedManually
        updatedMission.reviewSchedule = SpiderProductFeatures.postLaunchReviewLockedSchedule
        updatedMission.decisions = AdMissionUpdateApplier.mergedList(updatedMission.decisions, with: [
            "Marked as manually published. Spider did not publish or spend.",
        ])
        return updatedMission.sanitizedForLocalStorage()
    }
}
