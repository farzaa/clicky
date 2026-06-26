//
//  AdMissionArtifactApplier.swift
//  leanring-buddy
//
//  Applies sanitized Worker artifacts to the local Ad Mission without making
//  CompanionManager own artifact merge rules.
//

import Foundation

enum AdMissionArtifactApplier {
    static func applying(_ artifact: SpiderArtifact, to mission: AdMission) -> AdMission? {
        guard let sanitizedArtifact = artifact.sanitizedForLocalStorage() else {
            return nil
        }

        var updatedMission = mission
        updatedMission.artifacts.removeAll { existingArtifact in
            existingArtifact.kind == sanitizedArtifact.kind && existingArtifact.title == sanitizedArtifact.title
        }
        updatedMission.artifacts.append(sanitizedArtifact)
        return updatedMission.sanitizedForLocalStorage()
    }
}
