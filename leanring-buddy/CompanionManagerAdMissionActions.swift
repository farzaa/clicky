//
//  CompanionManagerAdMissionActions.swift
//  leanring-buddy
//
//  Local Ad Mission persistence and lifecycle actions for CompanionManager.
//  The manager owns state; AdMission domain policies own mutation rules.
//

import Foundation

@MainActor
extension CompanionManager {
    func saveAdMissionIfChanged(_ updatedMission: AdMission) {
        applyAdMissionPersistenceOutcome(
            AdMissionLocalPersistence.saveIfChanged(updatedMission, currentMission: adMission),
            failureDiagnostic: "ad mission save failed"
        )
    }

    func resetAdMission() {
        switch AdMissionLocalPersistence.reset() {
        case .saved(let emptyMission):
            setAdMissionState(emptyMission)
            clearAdMissionSessionContext()
        case .failed:
            SpiderDiagnostics.event("ad mission reset failed")
        case .unchanged, .rejectedInvalidArtifact:
            SpiderDiagnostics.event("ad mission reset failed")
        }
    }

    func startAdMissionFromOffer(_ draft: AdMissionOfferDraft) {
        saveAdMissionIfChanged(AdMissionStartBuilder.applying(draft, to: adMission))
        SpiderAnalytics.trackAdMissionCreated()
        SpiderAnalytics.trackCampaignPlanGenerated()
    }

    func requestPreflightAuditFromCurrentScreen() {
        guard ensureProductFeatureAvailable(.preflightAudit) else { return }

        saveAdMissionIfChanged(AdMissionLifecyclePolicy.preflightAuditRequested(adMission))

        SpiderAnalytics.trackPreflightAuditStarted()
        sendTranscriptToSpiderGuideWithScreenshot(
            transcript: "Audit this campaign before publishing. Separate Official Rule from Spider Judgment, identify Critical, Warnings, and Looks safe, and stop before any publish, spend, budget, billing, pause, or delete action.",
            platformContext: currentPlatformContextForGuide()
        )
    }

    func request72hReviewFromCurrentScreen() {
        guard ensureProductFeatureAvailable(.review72h) else { return }

        SpiderAnalytics.trackReview72hStarted()
        sendTranscriptToSpiderGuideWithScreenshot(
            transcript: "Review this running campaign conservatively. If spend, clicks, or conversions are too low, use needs_more_signal. Never suggest automatic pause, budget increase, billing action, or performance guarantees.",
            platformContext: currentPlatformContextForGuide()
        )
    }

    func markAdMissionAsManuallyPublished() {
        saveAdMissionIfChanged(AdMissionLifecyclePolicy.manuallyPublished(adMission))
    }

    private func applyAdMissionPersistenceOutcome(
        _ outcome: AdMissionLocalPersistenceOutcome,
        rejectedArtifactDiagnostic: StaticString? = nil,
        failureDiagnostic: StaticString
    ) {
        switch outcome {
        case .saved(let updatedMission):
            setAdMissionState(updatedMission)
        case .unchanged:
            break
        case .rejectedInvalidArtifact:
            if let rejectedArtifactDiagnostic {
                SpiderDiagnostics.event(rejectedArtifactDiagnostic)
            }
        case .failed:
            SpiderDiagnostics.event(failureDiagnostic)
        }
    }
}
