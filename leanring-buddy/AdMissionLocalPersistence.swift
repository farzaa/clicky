//
//  AdMissionLocalPersistence.swift
//  leanring-buddy
//
//  Applies local Ad Mission mutations and reports bounded persistence outcomes.
//

enum AdMissionLocalPersistenceOutcome: Equatable {
    case saved(AdMission)
    case unchanged
    case rejectedInvalidArtifact
    case failed
}

enum AdMissionLocalPersistence {
    static func persistArtifact(
        _ artifact: SpiderArtifact,
        to currentMission: AdMission,
        saveStore: (AdMission) throws -> Void = { try AdMissionStore.save($0) }
    ) -> AdMissionLocalPersistenceOutcome {
        guard let updatedMission = AdMissionArtifactApplier.applying(artifact, to: currentMission) else {
            return .rejectedInvalidArtifact
        }

        return save(updatedMission, saveStore: saveStore)
    }

    static func persistAdMissionUpdate(
        _ missionUpdate: AdMissionUpdate,
        to currentMission: AdMission,
        saveStore: (AdMission) throws -> Void = { try AdMissionStore.save($0) }
    ) -> AdMissionLocalPersistenceOutcome {
        saveIfChanged(
            AdMissionUpdateApplier.applying(missionUpdate, to: currentMission),
            currentMission: currentMission,
            saveStore: saveStore
        )
    }

    static func persistDecisionMemoryUpdate(
        _ decisionMemoryUpdate: String,
        to currentMission: AdMission,
        saveStore: (AdMission) throws -> Void = { try AdMissionStore.save($0) }
    ) -> AdMissionLocalPersistenceOutcome {
        saveIfChanged(
            AdMissionUpdateApplier.applyingDecisionMemoryUpdate(decisionMemoryUpdate, to: currentMission),
            currentMission: currentMission,
            saveStore: saveStore
        )
    }

    static func saveIfChanged(
        _ updatedMission: AdMission,
        currentMission: AdMission,
        saveStore: (AdMission) throws -> Void = { try AdMissionStore.save($0) }
    ) -> AdMissionLocalPersistenceOutcome {
        guard updatedMission != currentMission else { return .unchanged }
        return save(updatedMission, saveStore: saveStore)
    }

    static func save(
        _ updatedMission: AdMission,
        saveStore: (AdMission) throws -> Void = { try AdMissionStore.save($0) }
    ) -> AdMissionLocalPersistenceOutcome {
        do {
            try saveStore(updatedMission)
            return .saved(updatedMission)
        } catch {
            return .failed
        }
    }

    static func reset(
        resetStore: () throws -> AdMission = { try AdMissionStore.reset() }
    ) -> AdMissionLocalPersistenceOutcome {
        do {
            return .saved(try resetStore())
        } catch {
            return .failed
        }
    }
}
