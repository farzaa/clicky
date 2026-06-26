//
//  CompanionGuideResponseRecorder.swift
//  leanring-buddy
//
//  Applies local state side effects from validated guide responses. Raw
//  transcript and model text stay in bounded memory only; analytics receive
//  counts, not content.
//

import Foundation

struct CompanionGuideResponseRecorder {
    typealias SaveStore = (AdMission) throws -> Void

    private var conversationHistory = SpiderGuideConversationHistory()
    private let saveStore: SaveStore

    init(saveStore: @escaping SaveStore = { try AdMissionStore.save($0) }) {
        self.saveStore = saveStore
    }

    var conversationTurns: [(userTranscript: String, assistantResponse: String)] {
        conversationHistory.turns
    }

    mutating func removeAllConversationContext() {
        conversationHistory.removeAll()
    }

    mutating func record(
        _ guideResponse: SpiderGuideResponse,
        userTranscript: String,
        adMission: inout AdMission
    ) {
        if let artifact = guideResponse.artifact {
            applyPersistenceOutcome(
                AdMissionLocalPersistence.persistArtifact(artifact, to: adMission, saveStore: saveStore),
                to: &adMission,
                rejectedArtifactDiagnostic: "ad mission ignored invalid artifact",
                failureDiagnostic: "ad mission save failed"
            )
        }

        if let adMissionUpdate = guideResponse.adMissionUpdate {
            applyPersistenceOutcome(
                AdMissionLocalPersistence.persistAdMissionUpdate(adMissionUpdate, to: adMission, saveStore: saveStore),
                to: &adMission,
                failureDiagnostic: "ad mission save failed"
            )
        }

        if let decisionMemoryUpdate = guideResponse.decisionMemoryUpdate {
            applyPersistenceOutcome(
                AdMissionLocalPersistence.persistDecisionMemoryUpdate(
                    decisionMemoryUpdate,
                    to: adMission,
                    saveStore: saveStore
                ),
                to: &adMission,
                failureDiagnostic: "ad mission save failed"
            )
        }

        conversationHistory.append(
            userTranscript: userTranscript,
            assistantResponse: guideResponse.displayText
        )

        SpiderDiagnostics.count("conversation_history_count", conversationHistory.count)
        SpiderAnalytics.trackAIResponseReceived(responseCharacterCount: guideResponse.displayText.count)
    }

    private func applyPersistenceOutcome(
        _ outcome: AdMissionLocalPersistenceOutcome,
        to adMission: inout AdMission,
        rejectedArtifactDiagnostic: StaticString? = nil,
        failureDiagnostic: StaticString
    ) {
        switch outcome {
        case .saved(let updatedMission):
            adMission = updatedMission
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
